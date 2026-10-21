# typed: true
# frozen_string_literal: true

# The one way the server tells the SPA that something changed.
#
# The SPA never polls. It shows what it fetched, and it refetches when a
# Pusher message says a thing is stale (the client half of the protocol is
# app/frontend/src/helpers/pusher_client.js). So every write that changes
# what a screen shows must end in a push, whoever made the write: the
# API, ActiveAdmin, the nightly rotation job, a settlement, a rake task.
# The models own that: their save and destroy callbacks call the three
# methods below. A controller does not push; it only supplies the
# sender's socket id (Current.socket_id) and the request's push token
# (Current.push_token), which decide who is sent the meal page's push
# (see #meal).
#
# Three channels:
#
#   community-<id>-calendar-<year>-<month>  a calendar month. The name is
#                                           also the server cache key for
#                                           that month, on purpose.
#   meal-<id>                               one meal's page.
#   community-<id>-residents                anything that lists residents:
#                                           the hosts dropdown, the meal
#                                           page's sign-up list, and every
#                                           calendar month (names on
#                                           chips, birthdays).
#
# Batching. A request can write many rows (a bills save writes one row
# for each cook it adds, changes or removes), and each row's callback
# calls in here. The calls are
# collected per database transaction and flushed once, after the
# outermost transaction commits: one cache clear per month, one push per
# channel. A rolled-back transaction flushes nothing — its callbacks are
# dropped with it, which is what ActiveRecord::Transaction#after_commit
# does. A call with no transaction open flushes right away. A savepoint
# gets its own batch, so a month noted inside two savepoints is pushed
# twice: an event or a booking saves in a savepoint of its own
# (ConstraintMessages), so two of them saved in one transaction push
# each month twice. A second push only makes a screen fetch again.
#
# The flush clears every cache entry itself, at once: the clear is what
# keeps the next fetch correct. Each push is then handed to LivePushJob,
# and Solid Queue makes the HTTP call to Pusher outside the request. The
# request never waits on Pusher, so a slow Pusher cannot turn a committed
# write into a timeout (LivePushJob says how long that wait could be).
# Enqueuing is a small transaction of its own, at SERIALIZABLE like
# everything else, so Postgres can refuse it for a conflict; it is then
# tried again the way the API's meal writes are (RetryOnConflict).
#
# Nothing in the flush raises. It runs after the commit, and for the
# API's meal writes and for a settlement it runs inside the block that
# RetryOnConflict runs again on a conflict. A raise here would not only
# answer 500 for a change that is in the database: RetryOnConflict would
# take it for a rolled-back write and run the block again, and the
# committed write would be made a second time (a guest added twice; a
# settlement retried against meals it already claimed). Until 2026-09-21
# the cache clear could do exactly that: it is a DELETE on
# solid_cache_entries in the same SERIALIZABLE session, Postgres can
# refuse it, and solid_cache's failsafe does not swallow a serialization
# failure (spec/requests/api/v1/live_update_cache_clear_refused_spec.rb).
# So every step of the flush reports its failure (Rails.error.report)
# and goes on. A missed clear costs nothing: the month entry is keyed by
# a version read from the rows (CLAUDE.md, rule 8), so a stale entry is
# a miss anyway. A client that missed a push refetches on its next
# reconnect (data_store_app.js handleReconnect).
module LiveUpdate
  # What one transaction (or one manual batch) has to tell the clients.
  class Batch
    # What a batch knows about one meal's push: the socket the first note
    # named, the push tokens of the requests that noted it, and whether a
    # note came with no token (a change no page can call its own).
    MealNote = Struct.new(:socket_id, :tokens, :untokened)

    attr_reader :dates, :meals

    def initialize
      @dates = Set.new
      @meals = {}
      @residents = false
    end

    def residents?
      @residents
    end

    def residents!
      @residents = true
    end

    def empty?
      dates.empty? && meals.empty? && !residents?
    end
  end

  class << self
    # A calendar day changed: every month that shows it is stale. `date`
    # is a Date, or a Time (an event's start), which counts in the
    # community's time zone — the same zone the calendar is drawn in.
    def calendar(date)
      return if date.nil?

      note { |batch| batch.dates << community_date(date) }
    end

    # Every day from `from` to `to` changed (an event that spans months).
    # The first day of each month is kept, and the last day itself: the
    # months are what the cache and the channels are keyed by, and a day
    # late in a month is also on the next month's six-week grid. The first
    # day is not kept on its own: its month's first day reaches every
    # month it does (mutant, 2026-09-25).
    def calendar_range(from, to)
      return if from.nil?

      first = community_date(from)
      last = to.nil? ? first : community_date(to)
      note do |batch|
        month = first.beginning_of_month
        while month <= last
          batch.dates << month
          month = month.next_month
        end
        batch.dates << last
      end
    end

    # A meal's page is stale. Who is sent the push depends on the request
    # that made the change (ADR 0007, amended 2026-10-21 for #237):
    #
    # - With a push token (the six requests of the meal page's sign-up
    #   list send one): every screen, the sender's too, and the push
    #   carries the token. The sender skips it while it still waits for
    #   that request's answer or has it, because the answer shows the
    #   change. But a request the page gave up on (no answer after 35 s)
    #   can still be written, and then only this push tells that page.
    # - Without one (the meal page's other writes, and pages loaded
    #   before push tokens): every screen but the sender's socket, which
    #   updated its own screen and evicted its own copy
    #   (helpers/meal_cache.js).
    def meal(meal_id, socket_id: Current.socket_id, push_token: Current.push_token)
      note do |batch|
        # A later call for the same meal without a socket id (a callback
        # outside the request) must not un-exclude the sender, and a
        # call with one must not exclude it from a change it did not
        # make. The first caller wins.
        entry = (batch.meals[meal_id] ||= Batch::MealNote.new(socket_id, Set.new, false))
        if push_token
          entry.tokens << push_token
        else
          entry.untokened = true
        end
      end
    end

    # A resident or unit changed in a way some screen shows.
    def residents
      note(&:residents!)
    end

    # Collect everything noted inside the block into one flush. For
    # code that runs outside a transaction and notes many things — a
    # settlement's after-commit step, a rotation recolor.
    def batch
      if Current.live_update_manual_batch
        yield
        return
      end

      Current.live_update_manual_batch = Batch.new
      begin
        yield
      ensure
        pending = Current.live_update_manual_batch
        Current.live_update_manual_batch = nil
        flush(pending)
      end
    end

    # Clears caches and pushes. Public so a spec can call it on a batch
    # of its own; everything else goes through the methods above. Never
    # raises (see the header): each clear and each push reports its own
    # failure, and the rescue below catches the reads that name the keys.
    def flush(batch)
      return if batch.blank?

      community = Community.instance
      keys = batch.dates.flat_map { |date| community.affected_calendar_keys(date) }.uniq

      keys.each { |key| clear(key) }

      keys.each { |key| push(key, { message: 'calendar updated' }) } # rubocop:disable Style/CombinableLoops -- every clear must run before any push
      batch.meals.each { |meal_id, entry| push_meal(meal_id, entry) }
      push("community-#{community.id}-residents", { message: 'residents updated' }) if batch.residents?
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { dates: batch.dates.map(&:iso8601) })
    end

    private

    def note
      if (manual = Current.live_update_manual_batch)
        yield manual
      elsif (transaction = ActiveRecord::Base.current_transaction).open?
        yield batch_for(transaction)
      else
        batch = Batch.new
        yield batch
        flush(batch)
      end
    end

    # One batch per open transaction, keyed by the transaction's uuid.
    # Registered on the innermost transaction: Rails moves the callback
    # to the parent when a savepoint commits, and drops it when one rolls
    # back, so the flush runs exactly once, after the outermost commit,
    # or never.
    def batch_for(transaction)
      batches = (Current.live_update_batches ||= {})
      batches[transaction.uuid] ||= Batch.new.tap do |batch|
        transaction.after_commit do
          batches.delete(transaction.uuid)
          flush(batch)
        end
        transaction.after_rollback { batches.delete(transaction.uuid) }
      end
    end

    # A push with tokens goes to every screen and names them, so the
    # sender can tell its own request's push from any other (#meal). A
    # batch that also has a note with no token goes to every screen with
    # no tokens: no page may skip it, since a change in it is not any
    # page's own. One request's notes all carry its token, so this
    # happens only when other code notes the same meal in the same batch.
    def push_meal(meal_id, entry)
      if entry.tokens.any?
        data = { message: 'meal updated' }
        data[:push_tokens] = entry.tokens.to_a unless entry.untokened
        push("meal-#{meal_id}", data)
      else
        push("meal-#{meal_id}", { message: 'meal updated' }, entry.socket_id && { socket_id: entry.socket_id })
      end
    end

    # A Date comes back as itself (midnight in the zone, then the date).
    def community_date(value)
      value.in_time_zone(Community.instance.timezone).to_date
    end

    # A DELETE on solid_cache_entries, which Postgres can refuse like any
    # other statement at SERIALIZABLE. The write is committed and the
    # caller must not fail (and must not be retried), so a refusal is
    # reported and the entry is left to its version.
    def clear(key)
      Rails.cache.delete(key)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { key: key })
    end

    def push(channel, data, options = nil)
      RetryOnConflict.call { LivePushJob.perform_later(channel, data, options) }
    rescue StandardError => e
      # Whatever went wrong on the way to the queue, the write is
      # committed and the caller must not fail.
      Rails.error.report(e, handled: true, context: { channel: channel })
    end
  end
end
