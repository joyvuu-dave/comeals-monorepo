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
# sender's socket id (Current.socket_id) so the sender is not told to
# refetch a change it made itself.
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
# per cook), and each row's callback calls in here. The calls are
# collected per database transaction and flushed once, after the
# outermost transaction commits: one cache clear per month, one push per
# channel. A rolled-back transaction flushes nothing — its callbacks are
# dropped with it, which is what ActiveRecord::Transaction#after_commit
# does. A call with no transaction open flushes right away.
#
# The flush clears every cache entry before it sends the first push. A
# push is an HTTP call to Pusher and can fail; the clear is what keeps
# the next fetch correct, so it must not wait behind a push that may
# raise. And a push that fails is reported, not raised: the write has
# committed, and raising here would answer 500 for a change that is in
# the database. A client that missed a push refetches on its next
# reconnect (data_store_app.js handleReconnect).
module LiveUpdate
  # What one transaction (or one manual batch) has to tell the clients.
  class Batch
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
    # Only the first day of each month is kept: the months are what the
    # cache and the channels are keyed by.
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
        batch.dates << first
        batch.dates << last
      end
    end

    # A meal's page is stale. The sender's socket (the browser whose
    # request made the change) is excluded from the push: it updated its
    # own screen and evicted its own copy (helpers/meal_cache.js).
    def meal(meal_id, socket_id: Current.socket_id)
      note do |batch|
        # A later call for the same meal without a socket id (a callback
        # outside the request) must not un-exclude the sender, and a
        # call with one must not exclude it from a change it did not
        # make. The first caller wins.
        batch.meals[meal_id] = socket_id unless batch.meals.key?(meal_id)
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
    # of its own; everything else goes through the methods above.
    def flush(batch)
      return if batch.blank?

      community = Community.instance
      keys = batch.dates.flat_map { |date| community.affected_calendar_keys(date) }.uniq

      keys.each { |key| Rails.cache.delete(key) }

      keys.each { |key| push(key, { message: 'calendar updated' }) } # rubocop:disable Style/CombinableLoops -- every clear must run before any push
      batch.meals.each do |meal_id, socket_id|
        push("meal-#{meal_id}", { message: 'meal updated' }, socket_id && { socket_id: socket_id })
      end
      push("community-#{community.id}-residents", { message: 'residents updated' }) if batch.residents?
    end

    private

    def note
      if (manual = Current.live_update_manual_batch)
        yield manual
        return
      end

      transaction = ActiveRecord::Base.current_transaction
      unless transaction.open?
        batch = Batch.new
        yield batch
        flush(batch)
        return
      end

      yield batch_for(transaction)
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

    def community_date(value)
      return value if value.is_a?(Date)

      value.in_time_zone(Community.instance.timezone).to_date
    end

    def push(channel, data, options = nil)
      if options
        Pusher.trigger(channel, 'update', data, options)
      else
        Pusher.trigger(channel, 'update', data)
      end
    rescue StandardError => e
      # Whatever went wrong on the way to Pusher (its own errors, DNS, a
      # timeout), the write is committed and the caller must not fail.
      Rails.error.report(e, handled: true, context: { channel: channel })
    end
  end
end
