# frozen_string_literal: true

require 'rails_helper'

# A correction to a settled dinner is carried by exactly one settlement
# (ADR 0011 rule 6). A settlement claims the waiting corrections the way
# it claims meals: FOR UPDATE, then an update only where no settlement
# carries one yet (Settlement#claim_corrections). These race it against
# the two writers that could break that: a correction saved while the
# settlement runs, and a second settlement.
#
# Real commits, so a second session's statement can be in flight while
# the settlement's transaction is open (spec/db/settlement_race_spec.rb
# has the same set-up and explains it).
RSpec.describe 'claiming corrections, against a correction or a settlement at the same moment' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  let!(:settled) { dinner(latest - 5).tap { settle!(cutoff: latest - 5) }.reload }

  def dinner(date, cost: 30)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(cost.to_s))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

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

  def balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  # A correction saved from another session while a settlement is open:
  # the cook's $30 cost becomes $20, written the way MealCorrecting writes
  # it, and left uncommitted until the settlement has claimed.
  it 'leaves a correction saved during a settlement for the next settlement' do
    dinner(latest)
    writer = open_session
    writer.exec('BEGIN')
    writer.exec_params("SELECT set_config('comeals.correcting', $1, true)", [settled.id.to_s])
    writer.exec_params('UPDATE bills SET amount = 20 WHERE meal_id = $1', [settled.id])
    correction_id = writer.exec_params(
      'INSERT INTO meal_corrections (meal_id, admin_user_id, reason, created_at, updated_at) ' \
      "VALUES ($1, $2, 'Typed $30 for $20', now(), now()) RETURNING id", [settled.id, admin.id]
    ).getvalue(0, 0).to_i
    writer.exec_params(
      'INSERT INTO meal_correction_lines (meal_correction_id, resident_id, amount, created_at, updated_at) ' \
      'VALUES ($1, $2, -10, now(), now()), ($1, $3, 10, now(), now())', [correction_id, cook.id, eater.id]
    )

    during = settle!(cutoff: latest)
    writer.exec('COMMIT')

    expect(during.meal_corrections).to be_empty
    expect(MealCorrection.find(correction_id).reconciliation_id).to be_nil

    after = settle!(cutoff: latest)
    expect(MealCorrection.find(correction_id).reconciliation_id).to eq(after.id)
    expect(balances(after)).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    expect { LedgerVerification.call }.not_to raise_error
  ensure
    writer&.close
  end

  # Two settlements that would each carry the one waiting correction. Only
  # one survives, and it carries the correction once. Which side loses
  # depends on the isolation level, as in settlement_race_spec.rb: SSI may
  # cancel the first, or the second meets the claimed row.
  it 'lets exactly one of two racing settlements carry the correction' do
    correction = MealCorrecting.save!(settled, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end
    observer = open_session
    rival = nil
    blocked = false
    claimed = false
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |event|
      next if claimed || event.payload[:name] != 'MealCorrection Update All'

      claimed = true
      rival = Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection { Settlement.run!(cutoff: latest) }
      end
      blocked = wait_for_blocked_session(observer, 'FOR UPDATE')
    end

    main_error = begin
      Settlement.run!(cutoff: latest)
      nil
    rescue StandardError => e
      e
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    rival_error = begin
      rival.value
      nil
    rescue StandardError => e
      e
    end

    expect(blocked).to be(true)
    expect([main_error, rival_error].compact.size).to eq(1)
    expect([main_error, rival_error].compact.first)
      .to be_a(ActiveRecord::SerializationFailure).or be_a(Settlement::Contested)
    survivor = Reconciliation.where.not(id: settled.reconciliation_id).sole
    expect(correction.reload.reconciliation_id).to eq(survivor.id)
    expect(balances(survivor)).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
  ensure
    observer&.close
  end
end
