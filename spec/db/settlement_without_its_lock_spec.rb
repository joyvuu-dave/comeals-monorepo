# frozen_string_literal: true

require 'rails_helper'

# ADR 0003 says three pieces keep a settlement and an unlocked write from
# disagreeing: the settlement's FOR UPDATE on the meal rows, the
# compare-and-swap claim, and the child-write trigger. It says they "were
# each tested alone and neither works". That test was made when the
# trigger only read the meal row FOR KEY SHARE. Since 2026-10-16 the
# trigger updates the meal row, and the TLA+ model (docs/models.md, "What
# the cases say about the three pieces") says that at SERIALIZABLE the
# trigger alone is enough. The model is not the database, so this file
# runs a real settlement with its FOR UPDATE taken out, against a raw
# write on a psql-like session (READ COMMITTED, no lock of its own).
#
# assign_meals below is Settlement#assign_meals with `.lock` removed and a
# pause added on the first try: before the claim (the write commits
# entirely between the settlement's snapshot and its claim, so nothing
# ever waits), or after the claim (the write starts while the settlement
# is still open). The compare-and-swap stays; it is about two
# settlements, which this file does not race.
#
# If an example here fails, the trigger alone does not keep the ledger
# right, and the settlement's lock is required after all.
RSpec.describe 'a settlement without its FOR UPDATE, against a raw write' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:meal) { create(:meal, community: community, date: latest) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:latecomer) { create(:resident, community: community, unit: unit, multiplier: 2) }
  # Signed up too, so the meal still has someone to charge when an
  # example takes the eater off it.
  let(:neighbour) { create(:resident, community: community, unit: unit, multiplier: 2) }

  let(:add_latecomer) do
    <<~SQL.squish
      INSERT INTO meal_residents (meal_id, resident_id, community_id, multiplier, late, vegetarian,
                                  created_at, updated_at)
      VALUES (#{meal.id}, #{latecomer.id}, #{community.id}, 2, false, false, now(), now())
    SQL
  end
  let(:remove_eater) { "DELETE FROM meal_residents WHERE meal_id = #{meal.id} AND resident_id = #{eater.id}" }
  let(:raise_the_cost) { "UPDATE bills SET amount = 45 WHERE meal_id = #{meal.id} AND resident_id = #{cook.id}" }

  before do
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:meal_resident, meal: meal, resident: neighbour, community: community)
    latecomer
  end

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    session = PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password],
                         dbname: db[:database])
    # A write before the claim runs on the settlement's own thread. If it
    # ever waited for the settlement, that would never end; this ends it.
    session.exec("SET lock_timeout = '10s'")
    session
  end

  # Settlement#assign_meals without `.lock`. `before_claim` and
  # `after_claim` run on the first try only; a retry after a conflict
  # runs straight through.
  def take_out_the_lock(before_claim: -> {}, after_claim: -> {})
    tries = 0
    # rubocop:disable RSpec/AnyInstance -- the method under test is private to one Settlement
    allow_any_instance_of(Settlement).to receive(:assign_meals) do |settlement|
      # rubocop:enable RSpec/AnyInstance
      tries += 1
      meal_ids = settlement.send(:eligible_meal_ids)
      read = Meal.where(id: meal_ids).order(:id).pluck(:id, :date)
      before_claim.call if tries == 1
      claimed = Meal.where(id: meal_ids, reconciliation_id: nil)
                    .update_all(reconciliation_id: settlement.reconciliation.id)
      settlement.instance_variable_set(:@claimed_meals, read)
      after_claim.call if tries == 1
      raise Settlement::Contested, 'claimed fewer meals than it read' unless claimed == meal_ids.size
    end
    -> { tries }
  end

  # A raw write in a transaction of its own, committed. Returns nil, or
  # the error the database answered with.
  def raw_write(sql)
    session = open_session
    session.exec(sql)
    nil
  rescue PG::Error => e
    e
  ensure
    session&.close
  end

  def settle
    SettleAndNotify.call(cutoff: latest)
    :settled
  end

  # What the settlement stored for the meal, against what the meal's rows
  # say now. These must match whenever the meal is settled.
  def stored_and_from_rows
    reconciliation = Reconciliation.find(Meal.find(meal.id).reconciliation_id)
    stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
    from_rows = reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
    [stored, from_rows]
  end

  def expect_stored_to_match_the_rows
    stored, from_rows = stored_and_from_rows
    expect(stored).to eq(from_rows),
                      "the settlement stored #{stored.transform_values { |a| a.to_s('F') }}, but the meal's rows " \
                      "say #{from_rows.transform_values { |a| a.to_s('F') }}"
  end

  # The write commits after the settlement took its snapshot and before
  # it claims the meal. Nothing waits. The write's trigger updated the
  # meal row, so the claim's UPDATE of that row fails as a conflict, and
  # SettleAndNotify tries again with a snapshot that has the write in it.
  describe 'a write that commits between the snapshot and the claim' do
    {
      'a sign-up added' => :add_latecomer,
      'a sign-up removed' => :remove_eater,
      'a cost changed' => :raise_the_cost
    }.each do |name, sql|
      it "is counted: #{name}" do
        errors = []
        tries = take_out_the_lock(before_claim: -> { errors << raw_write(public_send(sql)) })

        expect(settle).to eq(:settled)
        expect(errors).to eq([nil])
        expect_stored_to_match_the_rows
        # The first try failed as a conflict at the claim. With the trigger
        # only reading the meal row (as before 2026-10-16), the first try
        # settles without the write, and both checks fail.
        expect(tries.call).to eq(2)
      end
    end
  end

  # The write starts after the claim, while the settlement is still open.
  # The trigger's update of the meal row waits for the settlement's
  # claim, then sees the meal settled and refuses.
  describe 'a write that starts after the claim' do
    def waiting_for_a_lock?(observer)
      observer.exec(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND pid <> pg_backend_pid() AND wait_event_type = 'Lock'"
      ).getvalue(0, 0).to_i.positive?
    end

    def start_and_wait_for(sql, writes)
      observer = open_session
      writes << Thread.new do
        Thread.current.report_on_exception = false
        raw_write(sql)
      end
      waited = false
      200.times do
        break unless writes.last.alive?

        waited = waiting_for_a_lock?(observer)
        break if waited

        sleep 0.02
      end
      writes << waited
    ensure
      observer&.close
    end

    {
      'a sign-up added' => :add_latecomer,
      'a sign-up removed' => :remove_eater,
      'a cost changed' => :raise_the_cost
    }.each do |name, sql|
      it "is refused: #{name}" do
        writes = []
        take_out_the_lock(after_claim: -> { start_and_wait_for(public_send(sql), writes) })

        expect(settle).to eq(:settled)
        thread, waited = writes
        error = thread.value

        expect(waited).to be(true)
        expect(error).to be_a(PG::RaiseException)
        expect(error.message).to include('reconciled')
        expect_stored_to_match_the_rows
      end
    end
  end
end
