# frozen_string_literal: true

require 'rails_helper'

# A correction to a settled dinner is carried by the next settlement (ADR
# 0011 rule 6): its lines go into that settlement's balances, the old
# settlement keeps what it settled, the running balances show it until a
# settlement carries it, and the nightly check agrees with all of it.
RSpec.describe Settlement do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }
  # A $30 dinner, settled; then its cost corrected to $20: the cook is
  # credited $10 less and the eater charged $10 less.
  let!(:corrected) { dinner(latest - 5, cost: 30) }
  let!(:first) { settle!(cutoff: latest - 5) }
  let!(:correction) do
    MealCorrecting.save!(corrected.reload, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end
  end

  def dinner(date, cost:)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(cost.to_s))
      create(:meal_resident, meal: meal, resident: eater, community: community)
    end
  end

  def balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  describe 'the next settlement' do
    it 'carries the correction: its lines are in the balances, and it names the settlement' do
      dinner(latest, cost: 12)

      second = settle!(cutoff: latest)

      expect(correction.reload.reconciliation).to eq(second)
      # $12 for the new dinner, and $10 back the other way for the old one.
      expect(balances(second)).to eq(cook.id => BigDecimal('2'), eater.id => BigDecimal('-2'))
      expect(second.meal_corrections).to eq([correction])
    end

    it 'leaves the first settlement as it settled' do
      dinner(latest, cost: 12)

      expect { settle!(cutoff: latest) }.not_to(change { balances(first) })
      expect(balances(first)).to eq(cook.id => BigDecimal('30'), eater.id => BigDecimal('-30'))
    end

    it 'carries a correction even with no new dinner to settle' do
      second = settle!(cutoff: latest)

      expect(second.meals).to be_empty
      expect(balances(second)).to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    end

    # The race claim_corrections guards against, made to happen inside one
    # transaction the way reconciliation_spec.rb makes the meal claim's
    # happen: the locking read returns a correction a rival settlement has
    # already claimed. The update then claims fewer than it read, and the
    # settlement rolls back rather than carry a correction twice. (At
    # SERIALIZABLE the database usually refuses first:
    # spec/db/correction_claim_race_spec.rb.)
    it 'raises and rolls back instead of carrying a correction a rival settlement claimed first' do
      claimed = correction
      rival = settle!(cutoff: latest)
      waiting = MealCorrecting.save!(corrected.reload, by: admin, reason: 'Then $21') do |edits|
        edits.cost(cook, amount: BigDecimal('21'), no_cost: false)
      end
      allow(MealCorrection).to receive(:waiting).and_return(MealCorrection.where(id: [claimed.id, waiting.id]))

      expect { settle!(cutoff: latest) }.to raise_error(described_class::Contested, /claimed the rest first/)
      expect(Reconciliation.where.not(id: [first.id, rival.id])).to be_empty
      expect(waiting.reload.reconciliation_id).to be_nil
      expect(claimed.reload.reconciliation_id).to eq(rival.id)
    end

    it 'marks the time a correction was carried' do
      written = correction.updated_at

      settle!(cutoff: latest)

      expect(correction.reload.updated_at).to be > written
    end

    # A correction saved after the locking read is not locked, so this
    # settlement must not claim it: the next one carries it. Here the
    # locking read is made to miss the second correction, the way a
    # correction saved between the read and the claim is missed.
    it 'claims only the corrections its locking read returned' do
      later = MealCorrecting.save!(corrected.reload, by: admin, reason: 'Then $21') do |edits|
        edits.cost(cook, amount: BigDecimal('21'), no_cost: false)
      end
      allow(MealCorrection).to receive(:waiting).and_return(MealCorrection.where(id: correction.id))

      second = settle!(cutoff: latest)

      expect(correction.reload.reconciliation).to eq(second)
      expect(later.reload.reconciliation_id).to be_nil
    end

    # The setting is turned off once the claim is done, not left for the
    # ledger's write to turn off. When that write fails, its savepoint puts
    # the setting back to what it was before the write, which must be off.
    it 'turns the setting off after the claim, so a failed ledger write leaves it off' do
      reconciliation = Reconciliation.new(end_date: latest)
      allow(reconciliation).to receive(:settlement_balances).and_raise(RuntimeError, 'the write failed')

      ActiveRecord::Base.transaction do
        expect { described_class.new(reconciliation).settle! }.to raise_error(RuntimeError, 'the write failed')
        expect(ActiveRecord::Base.connection.select_value(
                 "SELECT current_setting('#{described_class::SETTLING_SETTING}', true)"
               )).to be_blank
      end
    end

    # The claim sets the database setting that names this settlement, and
    # runs in its own savepoint, as the ledger's write does
    # (settlement_spec.rb). Rolling the savepoint back undoes the setting
    # too. Without it, a caller that catches the error and keeps its
    # transaction would keep the setting.
    it 'turns the setting off again when the claim fails, even for a caller that catches the error' do
      allow(MealCorrection).to receive(:where).and_call_original
      allow(MealCorrection).to receive(:where).with(id: [correction.id], reconciliation_id: nil)
                                              .and_raise(RuntimeError, 'the claim failed')

      ActiveRecord::Base.transaction do
        expect { settle!(cutoff: latest) }.to raise_error(RuntimeError, 'the claim failed')
        expect(ActiveRecord::Base.connection.select_value(
                 "SELECT current_setting('#{described_class::SETTLING_SETTING}', true)"
               )).to be_blank
      end
    end

    it 'carries each correction once' do
      second = settle!(cutoff: latest)

      expect { settle!(cutoff: latest) }.to raise_error(ActiveRecord::RecordInvalid, /at least one meal or carry a/)
      expect(MealCorrection.waiting).to be_empty
      expect(correction.reload.reconciliation).to eq(second)
    end

    it 'shows the correction in the preview, with its lines in each person\'s amount' do
      dinner(latest, cost: 12)

      preview = described_class.preview(cutoff: latest)

      expect(preview.corrections).to eq([correction])
      expect(preview.resident_balances.slice(cook.id, eater.id))
        .to eq(cook.id => BigDecimal('2'), eater.id => BigDecimal('-2'))
      expect(balances(settle!(cutoff: latest))).to eq(preview.resident_balances.reject { |_, amount| amount.zero? })
    end

    # Rule 4: Create settles only what the preview showed. A correction
    # saved after the preview changes what the settlement carries.
    it 'refuses the preview\'s fingerprint when a correction was saved after the preview' do
      dinner(latest, cost: 12)
      fingerprint = described_class.preview(cutoff: latest).fingerprint
      MealCorrecting.save!(corrected.reload, by: admin, reason: 'And another') do |edits|
        edits.cost(cook, amount: BigDecimal('21'), no_cost: false)
      end

      expect do
        described_class.settle!(cutoff: latest, fingerprint: fingerprint)
      end.to raise_error(described_class::Changed)
      expect(MealCorrection.waiting.count).to eq(2)
    end
  end

  describe 'the running balances' do
    it 'add a correction no settlement carries yet, and drop it once one does' do
      BalanceRecalculation.call(community: community)
      expect(ResidentBalance.where(resident: [cook, eater]).pluck(:resident_id, :amount).to_h)
        .to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))

      settle!(cutoff: latest)
      BalanceRecalculation.call(community: community)
      expect(ResidentBalance.where(resident: [cook, eater]).pluck(:amount)).to all(eq(0))
    end
  end

  describe 'the nightly check' do
    def findings
      LedgerVerification.new.call.details
    rescue LedgerVerification::MismatchError => e
      e.run.details
    end

    it 'finds nothing wrong with a corrected dinner, before and after a settlement carries it' do
      expect(findings).to eq([])

      dinner(latest, cost: 12)
      settle!(cutoff: latest)
      expect(findings).to eq([])
    end

    # A change no correction explains: psql with the repair bypass.
    it 'names a settled dinner whose rows changed without a correction' do
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT set_config('comeals.allow_settled_writes', 'on', true)")
      Bill.where(meal_id: corrected.id).update_all(amount: BigDecimal('26'))
      connection.execute("SELECT set_config('comeals.allow_settled_writes', '', true)")

      dinners = findings.select { |detail| detail['check'] == 'dinners' }
      expect(dinners.sole['differences']).to contain_exactly(
        { 'meal_id' => corrected.id, 'meal_date' => corrected.date.to_s, 'resident_id' => cook.id,
          'stored' => '20.0', 'source' => '26.0' },
        { 'meal_id' => corrected.id, 'meal_date' => corrected.date.to_s, 'resident_id' => eater.id,
          'stored' => '-20.0', 'source' => '-26.0' }
      )
      expect(findings.pluck('check')).to include('recompute')
    end

    it 'adds a carried correction\'s lines in the line item check' do
      second = settle!(cutoff: latest)

      expect(MealCharge.for_reconciliation(second)).to be_empty
      expect(findings).to eq([])
    end

    # A settlement that carries a correction and settles no dinner has no
    # meal lines, only the correction's lines. The line item check still
    # compares those with its balances.
    it 'checks the line items of a settlement that carries a correction and settles no dinner' do
      second = settle!(cutoff: latest)
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT set_config('comeals.allow_settled_writes', 'on', true)")
      second.reconciliation_balances.where(resident: cook).update_all(amount: BigDecimal('-9'))
      second.reconciliation_balances.where(resident: eater).update_all(amount: BigDecimal('9'))
      connection.execute("SELECT set_config('comeals.allow_settled_writes', '', true)")

      expect(findings.select { |detail| detail['reconciliation_id'] == second.id }.pluck('check'))
        .to contain_exactly('recompute', 'line_items')
    end
  end
end
