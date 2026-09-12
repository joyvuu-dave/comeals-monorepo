# frozen_string_literal: true

require 'rails_helper'

# The batching rules of LiveUpdate on their own. The contract every model
# keeps with it is pinned in spec/requests/api/v1/live_update_contract_spec.rb.
#
# Under mutant, a `describe '.method'` group is the whole test set for
# that method: nothing described by a sentence, and no mapped file, is
# added to it. So each group below holds every example that proves its
# method (2026-09-12: `.calendar_range` had one example, and deleting the
# method's body survived).
RSpec.describe LiveUpdate do
  let(:community) { create(:community) }

  before { community }

  # What one flush pushed, by channel.
  def pushed
    calls = []
    allow(Pusher).to receive(:trigger) { |channel, _event, data, options = nil| calls << [channel, data, options] }
    yield
    calls
  end

  def calendar_channels(calls)
    calls.map(&:first).grep(/calendar/).sort
  end

  describe '.calendar_range' do
    it 'notes nothing for a range with no start' do
      described_class.calendar_range(nil, Date.new(2026, 4, 1))

      expect(Pusher).not_to have_received(:trigger)
    end

    it 'marks every month from the first day to the last, not only the two ends' do
      # January 5 to May 20: February, March and April are only reached by
      # walking the months in between. The two ends alone would reach
      # December (its six-week window ends January 10), January and May.
      calls = pushed do
        described_class.batch { described_class.calendar_range(Date.new(2026, 1, 5), Date.new(2026, 5, 20)) }
      end

      expect(calendar_channels(calls)).to eq(
        %w[2025-12 2026-1 2026-2 2026-3 2026-4 2026-5].map { |m| "community-#{community.id}-calendar-#{m}" }
      )
    end

    it 'treats a range with no end as one day' do
      # The day itself, and the first of its month, which the month before
      # still shows in its sixth week.
      calls = pushed do
        described_class.batch { described_class.calendar_range(Date.new(2026, 4, 15), nil) }
      end

      expect(calendar_channels(calls)).to eq(%w[2026-3 2026-4].map { |m| "community-#{community.id}-calendar-#{m}" })
    end

    it "reads a time's day in the community's zone, not the app's" do
      # 16:00 UTC on July 25 is July 26 at 01:00 in Tokyo, and July 25 in the
      # app zone (Pacific). July 26 is the first day of August's six-week
      # window, so the Tokyo reading marks August and the Pacific one would
      # not.
      community.update!(timezone: 'Asia/Tokyo')
      calls = pushed do
        described_class.batch { described_class.calendar_range(Time.utc(2026, 7, 25, 16), Time.utc(2026, 7, 25, 17)) }
      end

      expect(calendar_channels(calls))
        .to eq(%w[2026-6 2026-7 2026-8].map { |m| "community-#{community.id}-calendar-#{m}" })
    end
  end

  describe '.calendar' do
    it "reads a time's day in the community's zone, not the time's own" do
      community.update!(timezone: 'Asia/Tokyo')
      calls = pushed do
        described_class.batch { described_class.calendar(Time.utc(2026, 6, 6, 16)) }
      end

      expect(calendar_channels(calls)).to eq(["community-#{community.id}-calendar-2026-6"])
    end

    it 'marks every month whose six weeks show the day' do
      calls = pushed do
        described_class.batch { described_class.calendar(Date.new(2026, 6, 6)) }
      end

      expect(calendar_channels(calls)).to eq(%w[2026-5 2026-6].map { |m| "community-#{community.id}-calendar-#{m}" })
    end
  end

  describe '.meal' do
    it 'pushes the meal channel without the sender when no socket id is known' do
      calls = pushed { described_class.batch { described_class.meal(7) } }

      expect(calls).to eq([['meal-7', { message: 'meal updated' }, nil]])
    end

    it 'leaves the sender out of the push, and the first caller decides who the sender is' do
      calls = pushed do
        described_class.batch do
          described_class.meal(7, socket_id: 'the-sender')
          described_class.meal(7, socket_id: 'someone-else')
          described_class.meal(7, socket_id: nil)
        end
      end

      expect(calls).to eq([['meal-7', { message: 'meal updated' }, { socket_id: 'the-sender' }]])
    end

    it 'does not exclude a sender from a meal it did not change' do
      calls = pushed do
        described_class.batch do
          described_class.meal(7, socket_id: nil)
          described_class.meal(7, socket_id: 'late-comer')
        end
      end

      expect(calls).to eq([['meal-7', { message: 'meal updated' }, nil]])
    end
  end

  describe '.batch' do
    it 'folds a batch opened inside another into the outer one, so there is one flush' do
      described_class.batch do
        described_class.batch { described_class.residents }
        described_class.residents
        expect(Pusher).not_to have_received(:trigger)
      end

      expect(Pusher).to have_received(:trigger)
        .with("community-#{community.id}-residents", 'update', { message: 'residents updated' }).once
    end

    it 'closes the batch even when the block raises, so the next note flushes on its own' do
      expect { described_class.batch { raise 'boom' } }.to raise_error('boom')

      described_class.residents

      expect(Pusher).to have_received(:trigger)
        .with("community-#{community.id}-residents", 'update', { message: 'residents updated' }).once
    end

    it 'flushes what the block noted, once, after the block' do
      calls = pushed do
        described_class.batch do
          described_class.residents
          described_class.residents
        end
      end

      expect(calls).to eq([["community-#{community.id}-residents", { message: 'residents updated' }, nil]])
    end
  end

  # Sentence-described, so these run for every LiveUpdate method under
  # mutant (flush, note, community_date, push, batch_for, Batch).
  describe 'what one flush sends' do
    it 'pushes nothing for an empty batch' do
      calls = pushed { described_class.batch { nil } }

      expect(calls).to be_empty
    end

    it 'pushes the residents channel only when a resident change was noted' do
      calls = pushed { described_class.batch { described_class.meal(7) } }

      expect(calls.map(&:first)).not_to include("community-#{community.id}-residents")
    end

    it 'clears every calendar entry before it pushes anything' do
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)
      key = community.calendar_cache_key(2026, 4)
      store.write(key, 'stale')
      seen_at_push = nil
      allow(Pusher).to receive(:trigger) { |*| seen_at_push = store.read(key) }

      described_class.batch { described_class.calendar(Date.new(2026, 4, 15)) }

      expect(seen_at_push).to be_nil
      expect(store.read(key)).to be_nil
    end

    it 'reports a push that fails, with the channel, and goes on to the next push' do
      allow(Pusher).to receive(:trigger).and_raise(Pusher::HTTPError, 'Pusher is down')
      allow(Rails.error).to receive(:report)

      described_class.batch do
        described_class.meal(7)
        described_class.residents
      end

      expect(Rails.error).to have_received(:report)
        .with(an_instance_of(Pusher::HTTPError), hash_including(handled: true, context: { channel: 'meal-7' }))
      expect(Rails.error).to have_received(:report)
        .with(an_instance_of(Pusher::HTTPError),
              hash_including(context: { channel: "community-#{community.id}-residents" }))
    end
  end

  # The two groups below commit for real. Their cleanup runs after the
  # outer `before` above, so they make the community again.
  describe 'a note with no transaction open' do
    include_context 'with no test transaction'

    before { create(:community) }

    it 'flushes at once' do
      calls = pushed { described_class.residents }

      expect(calls).to eq([["community-#{Community.instance.id}-residents", { message: 'residents updated' }, nil]])
    end
  end

  describe 'notes inside a transaction' do
    include_context 'with no test transaction'

    before { create(:community) }

    it 'flush once after the outermost commit, and leave nothing behind for the next write' do
      calls = pushed do
        ActiveRecord::Base.transaction do
          described_class.meal(7)
          # A nested transaction joins the outer one (no savepoint), so this
          # is the same batch.
          ActiveRecord::Base.transaction { described_class.meal(7) }
          described_class.residents
          expect(Pusher).not_to have_received(:trigger)
        end
      end

      expect(calls.map(&:first)).to contain_exactly('meal-7', "community-#{Community.instance.id}-residents")
      expect(Current.live_update_batches).to be_empty
    end

    # No app code opens a savepoint (there is no requires_new anywhere in
    # app/ or lib/). If one ever does, this is what it costs: a note inside
    # the savepoint is its own batch, flushed after the outer commit, so a
    # meal noted on both sides is pushed twice. Harmless — a client
    # refetches twice — and pinned here so the choice is a known one.
    it 'push a savepoint\'s notes as a batch of their own, after the outer commit' do
      calls = pushed do
        ActiveRecord::Base.transaction do
          described_class.meal(7)
          ActiveRecord::Base.transaction(requires_new: true) { described_class.meal(7) }
        end
      end

      expect(calls.map(&:first)).to eq(%w[meal-7 meal-7])
    end

    it 'drop everything when the transaction rolls back, and leave nothing behind' do
      calls = pushed do
        ActiveRecord::Base.transaction do
          described_class.residents
          raise ActiveRecord::Rollback
        end
      end

      expect(calls).to be_empty
      expect(Current.live_update_batches).to be_empty
    end
  end

  describe LiveUpdate::Batch do
    it 'is empty until something is noted, and not after' do
      expect(described_class.new).to be_empty
      expect(described_class.new.tap { |b| b.dates << Date.new(2026, 4, 1) }).not_to be_empty
      expect(described_class.new.tap { |b| b.meals[7] = nil }).not_to be_empty
      expect(described_class.new.tap(&:residents!)).not_to be_empty
    end
  end
end
