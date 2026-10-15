# frozen_string_literal: true

require 'rails_helper'

# The "Mark these dinners as cancelled" button cancels only dinners that
# still have no cook at the moment of the yes (ADR 0011 rule 11). This
# races it against a cook signing up through the app at that same
# moment, and the cook must win: the dinner is not cancelled.
#
# The cook's save takes the meal's lock first (LocksItsMealFirst), so
# the cancelling waits at its FOR UPDATE until the cook commits. Its
# transaction began before that commit, so its first read of the cooks
# is the old one, with no cook. Only the database's conflict check
# stops it: both transactions are SERIALIZABLE, and each read a row the
# other wrote. RetryOnConflict then reads the cooks again and leaves the
# dinner alone.
RSpec.describe 'marking dinners cancelled, against a cook signing up at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today)) }
  let(:cook) { create(:resident, community: community, unit: unit) }

  before { create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit)) }

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Waits until another session is blocked on a lock while running a
  # statement that contains `sql_fragment`.
  def wait_for_blocked_session(observer, sql_fragment)
    200.times do
      blocked = observer.exec_params(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE $1",
        ["%#{sql_fragment}%"]
      ).getvalue(0, 0).to_i.positive?
      return true if blocked

      sleep 0.02
    end
    false
  end

  it 'leaves the dinner alone, and never cancels it' do
    allow(Rails.error).to receive(:report).and_call_original
    observer = open_session
    signed_up = Queue.new
    go = Queue.new
    signing_up = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        Bill.transaction do
          Bill.create!(meal: meal, resident: cook, amount: 0)
          signed_up << true
          go.pop
        end
      end
    end
    signed_up.pop

    cancelling = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection { DinnerCancelling.call(meal_ids: [meal.id]) }
    end
    # The cook's save holds the meal's lock, so the cancelling waits at
    # its FOR UPDATE until the cook commits.
    expect(wait_for_blocked_session(observer, 'FOR UPDATE')).to be(true)
    go << true
    signing_up.join
    result = cancelling.value

    expect(result.cancelled).to eq([])
    expect(result.left_alone.map(&:reason)).to eq(['a cook signed up for it'])
    expect(meal.reload.cancelled?).to be(false)
    expect(meal.bills.pluck(:resident_id)).to eq([cook.id])
    # The first try read no cook, and the database refused its write; the
    # second try read the cooks again (RetryOnConflict).
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  ensure
    go&.push(true)
    signing_up&.join
    observer&.close
  end
end
