# frozen_string_literal: true

require 'rails_helper'

# Edges where the settlement rules of ADR 0011 meet: a correction (rule 6)
# next to a cancelled dinner (rule 11), a correction for someone who moved
# out or moved units (rule 7), and a correction to a capped dinner. Each
# one goes through a real settlement and the nightly check. Written by the
# money bug hunt of 2026-10-16, which found no spec for these.
RSpec.describe Settlement do
  let(:community) { create(:community) }
  let(:ash) { create(:unit, community: community, name: 'Ash') }
  let(:elm) { create(:unit, community: community, name: 'Elm') }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: ash, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: ash, name: 'Eater') }
  let(:other) { create(:resident, community: community, unit: ash, name: 'Other') }

  # Every eater here pays the adult price, so a dinner's cost is split
  # evenly.
  def dinner(date, amount, eaters:)
    create(:meal, community: community, date: date).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(amount))
      eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    end
  end

  def correct(meal, reason: 'A mistake found later', &)
    MealCorrecting.save!(meal.reload, by: admin, reason: reason, &)
  end

  def balances(reconciliation)
    reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
  end

  def lines(correction)
    correction.lines.pluck(:resident_id, :amount).to_h
  end

  def findings
    LedgerVerification.call.details
  rescue LedgerVerification::MismatchError => e
    e.run.details
  end

  describe 'a cancelled dinner in the settlement that carries a correction' do
    it 'settles the cancelled dinner at $0 next to a real one, and carries the correction' do
      first_dinner = dinner(latest - 10, '30', eaters: [eater])
      first = settle!(cutoff: latest - 10)
      correction = correct(first_dinner) { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }
      # Someone signed up and the cook's cost is blank, then it was
      # called off.
      cancelled = dinner(latest - 3, '0', eaters: [eater, other]).tap(&:cancel!)
      real = dinner(latest - 2, '12', eaters: [eater])

      preview = described_class.preview(cutoff: latest)
      second = described_class.settle!(cutoff: latest, fingerprint: preview.fingerprint).reconciliation

      expect(second.meals).to contain_exactly(cancelled, real)
      expect(cancelled.meal_charges.pluck(:amount)).to all(eq(0))
      expect(correction.reload.reconciliation).to eq(second)
      # $12 for the real dinner, and $10 back the other way for the
      # corrected one.
      expect(balances(second)).to eq(cook.id => BigDecimal('2'), eater.id => BigDecimal('-2'))
      expect(balances(first)).to eq(cook.id => BigDecimal('30'), eater.id => BigDecimal('-30'))
      expect(findings).to eq([])
    end
  end

  describe 'a correction for someone who moved out' do
    let(:gone) { create(:resident, community: community, unit: ash, name: 'Gone') }

    it 'charges them in the next settlement, on the moved-out line, and the totals still add up' do
      first_dinner = dinner(latest - 10, '30', eaters: [eater, gone])
      settle!(cutoff: latest - 10)
      gone.update!(active: false)
      correction = correct(first_dinner) { |edits| edits.cost(cook, amount: BigDecimal('36'), no_cost: false) }
      expect(lines(correction)).to eq(cook.id => BigDecimal('6'), eater.id => BigDecimal('-3'),
                                      gone.id => BigDecimal('-3'))

      second = settle!(cutoff: latest)

      expect(balances(second)).to eq(cook.id => BigDecimal('6'), eater.id => BigDecimal('-3'),
                                     gone.id => BigDecimal('-3'))
      gone_line = second.reconciliation_balances.find_by(resident: gone)
      expect(gone_line).to have_attributes(lived_here: false, unit_id: ash.id)
      expect(second.unit_balances).to eq([ash.id, 'Ash'] => BigDecimal('3'))
      expect(second.moved_out_balance).to eq(BigDecimal('-3'))
      expect(CollectionList.new(second).moved_out.map { |person| [person.name, person.amount] })
        .to eq([['Gone', BigDecimal('-3')]])
      expect(findings).to eq([])
    end
  end

  describe 'a correction for someone who moved units' do
    let(:cook) { create(:resident, community: community, unit: elm, name: 'Cook') }

    it 'keeps the old settlement in the old unit and puts the carried correction in the new one' do
      first_dinner = dinner(latest - 10, '30', eaters: [eater])
      first = settle!(cutoff: latest - 10)
      eater.update!(unit: elm)
      correct(first_dinner) { |edits| edits.cost(cook, amount: BigDecimal('20'), no_cost: false) }

      second = settle!(cutoff: latest)

      expect(first.reload.unit_balances).to eq([ash.id, 'Ash'] => BigDecimal('-30'),
                                               [elm.id, 'Elm'] => BigDecimal('30'))
      expect(second.unit_balances).to eq([ash.id, 'Ash'] => BigDecimal('0'), [elm.id, 'Elm'] => BigDecimal('0'))
      eater_line = second.reconciliation_balances.find_by(resident: eater)
      expect(eater_line).to have_attributes(unit_id: elm.id, lived_here: true)
      expect(findings).to eq([])
    end
  end

  describe 'a correction to a capped dinner' do
    it 'moves the cap with the eaters, moves no money for a cost still over the cap, and settles exactly' do
      # A $30 receipt under a $5 cap with one adult: the eater pays the
      # $10 the cap allows, and the cook is credited $10.
      capped = dinner(latest - 10, '30', eaters: [eater]).tap { |meal| meal.update!(cap: BigDecimal('5')) }
      first = settle!(cutoff: latest - 10)
      expect(balances(first)).to eq(cook.id => BigDecimal('10'), eater.id => BigDecimal('-10'))

      # A second adult raises what the cap allows to $20.
      added = correct(capped) { |edits| edits.add_eater(other) }
      expect(lines(added)).to eq(cook.id => BigDecimal('10'), other.id => BigDecimal('-10'))
      # $25 is still over the $20 the cap allows, so no money moves.
      over = correct(capped) { |edits| edits.cost(cook, amount: BigDecimal('25'), no_cost: false) }
      expect(lines(over)).to eq({})
      # $15 is under it, so the eaters pay $7.50 each.
      under = correct(capped) { |edits| edits.cost(cook, amount: BigDecimal('15'), no_cost: false) }
      expect(lines(under)).to eq(cook.id => BigDecimal('-5'), eater.id => BigDecimal('2.5'),
                                 other.id => BigDecimal('2.5'))

      second = settle!(cutoff: latest)

      expect(balances(second)).to eq(cook.id => BigDecimal('5'), eater.id => BigDecimal('2.5'),
                                     other.id => BigDecimal('-7.5'))
      expect(MealCostSummary.now(capped.reload)).to have_attributes(total_cost: BigDecimal('15'),
                                                                    effective_cost: BigDecimal('15'),
                                                                    subsidized: false)
      expect(findings).to eq([])
    end
  end
end
