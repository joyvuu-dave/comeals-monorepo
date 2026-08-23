# frozen_string_literal: true

require 'rails_helper'

# MealLedger's totals are already covered from both ends — by
# spec/tasks/billing_recalculate_correctness_spec.rb and
# spec/tasks/settlement_matches_running_balance_spec.rb, which run the real
# callers over whole datasets. This file covers what those cannot see: the
# individual lines, their signs, and the promise that the class runs no
# queries.
RSpec.describe MealLedger do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def resident(name, multiplier: 2)
    create(:resident, community: community, unit: unit, multiplier: multiplier, name: name)
  end

  # Loads the meals the way both callers do. MealLedger reads these three
  # associations and must never query for them itself.
  def ledger_for(*meals)
    described_class.new(Meal.where(id: meals.map(&:id)).preload(:bills, :meal_residents, :guests).to_a)
  end

  describe 'signs' do
    it 'credits a cook a positive amount and charges an eater a negative one' do
      cook = resident('Cook')
      eater = resident('Eater')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

      lines = ledger_for(meal).lines
      credit = lines.find { |line| line.kind == :credit }
      eater_debit = lines.find { |line| line.kind == :debit && line.resident_id == eater.id }

      expect(credit.amount).to eq(BigDecimal('50'))
      expect(eater_debit.amount).to eq(BigDecimal('-25'))
    end

    it 'makes a resident balance the plain sum of their own lines' do
      cook = resident('Cook')
      eater = resident('Eater')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

      ledger = ledger_for(meal)
      balances = ledger.balances([cook.id, eater.id])

      [cook, eater].each do |person|
        own_lines = ledger.lines.select { |line| line.resident_id == person.id }
        expect(balances[person.id]).to eq(own_lines.sum(BigDecimal('0'), &:amount))
      end

      expect(balances[cook.id]).to eq(BigDecimal('25'))
      expect(balances[eater.id]).to eq(BigDecimal('-25'))
    end

    it 'gives every requested resident an entry, including one who neither ate nor cooked' do
      cook = resident('Cook')
      absent = resident('Absent')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)

      balances = ledger_for(meal).balances([cook.id, absent.id])

      expect(balances.keys).to contain_exactly(cook.id, absent.id)
      expect(balances[absent.id]).to eq(BigDecimal('0'))
    end
  end

  describe 'lines' do
    it 'produces no line at all for a no_cost bill' do
      cook = resident('Cook')
      helper = resident('Helper')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:bill, meal: meal, resident: helper, community: community, amount: BigDecimal('12'), no_cost: true)
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: helper, community: community, multiplier: 2)

      credits = ledger_for(meal).lines.select { |line| line.kind == :credit }

      expect(credits.map(&:resident_id)).to eq([cook.id])
    end

    it 'charges a guest to the resident who brought them' do
      cook = resident('Cook')
      host = resident('Host')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: host, community: community, multiplier: 2)
      create(:guest, meal: meal, resident: host, multiplier: 2)

      guest_lines = ledger_for(meal).lines.select { |line| line.kind == :guest_debit }

      expect(guest_lines.length).to eq(1)
      expect(guest_lines.first.resident_id).to eq(host.id)
      expect(guest_lines.first.amount).to eq(BigDecimal('-20'))
    end

    it 'records what a cook spent alongside the smaller amount they are credited' do
      community.update!(cap: BigDecimal('4.50'))
      cook = resident('Cook')
      eater = resident('Eater')

      # 4 units of multiplier * 4.50 = 18.00 allowed, against 60.00 spent.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

      credit = ledger_for(meal).lines.find { |line| line.kind == :credit }

      expect(credit.amount).to eq(BigDecimal('18'))
      expect(credit.bill_amount).to eq(BigDecimal('60'))
      expect(credit.unit_cost).to eq(BigDecimal('4.50'))
    end

    it 'splits a subsidized credit between cooks in proportion to what each spent' do
      community.update!(cap: BigDecimal('4.50'))
      cook_a = resident('Cook A')
      cook_b = resident('Cook B')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook_a, community: community, amount: BigDecimal('40'))
      create(:bill, meal: meal, resident: cook_b, community: community, amount: BigDecimal('20'))
      create(:meal_resident, meal: meal, resident: cook_a, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: cook_b, community: community, multiplier: 2)

      credits = ledger_for(meal).lines.select { |line| line.kind == :credit }
      by_resident = credits.to_h { |line| [line.resident_id, line.amount] }

      # 40/60 does not terminate, so each credit carries a tail some thirty
      # digits down: 12.00000000000000000000000000000006 and
      # 5.99999999999999999999999999999994. That is why nothing is rounded
      # until settlement — the two tails cancel, and the split gives back
      # exactly what the eaters were charged. Rounding here would not.
      expect(by_resident[cook_a.id].round(8)).to eq(BigDecimal('12'))
      expect(by_resident[cook_b.id].round(8)).to eq(BigDecimal('6'))
      expect(by_resident.values.sum(BigDecimal('0'))).to eq(BigDecimal('18'))
    end

    it 'makes every amount zero on a meal whose attendees all have multiplier zero' do
      cook = resident('Cook')
      baby = resident('Baby', multiplier: 0)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      create(:meal_resident, meal: meal, resident: baby, community: community, multiplier: 0)

      ledger = ledger_for(meal)

      expect(ledger.lines.map(&:amount)).to all(eq(BigDecimal('0')))
      expect(ledger.lines.map(&:unit_cost)).to all(eq(BigDecimal('0')))
      expect(ledger.balances([cook.id, baby.id]).values).to all(eq(BigDecimal('0')))
    end

    it 'keeps fractional cents on a line instead of rounding them away' do
      cook = resident('Cook')
      children = [resident('Child A', multiplier: 1), resident('Child B', multiplier: 1)]

      # 53.17 across 2 units of multiplier is 26.585 per unit — half a cent.
      # The line must carry it exactly; settlement is the only place that
      # rounds, and it cannot round correctly from lines that already did.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('53.17'))
      children.each { |child| create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 1) }

      lines = ledger_for(meal).lines
      debits = lines.select { |line| line.kind == :debit }

      expect(debits.map(&:amount)).to all(eq(BigDecimal('-26.585')))
      expect(debits.map(&:unit_cost)).to all(eq(BigDecimal('26.585')))
      expect(lines.sum(BigDecimal('0'), &:amount)).to eq(BigDecimal('0'))
    end

    it 'carries the multiplier on a debit and leaves it off a credit' do
      cook = resident('Cook')
      child = resident('Child', multiplier: 1)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: child, community: community, multiplier: 1)

      lines = ledger_for(meal).lines

      expect(lines.find { |line| line.kind == :debit }.multiplier).to eq(1)
      expect(lines.find { |line| line.kind == :credit }.multiplier).to be_nil
      expect(lines.find { |line| line.kind == :debit }.bill_amount).to be_nil
    end
  end

  describe 'queries' do
    # The rake task reads its meals inside one SERIALIZABLE READ ONLY snapshot
    # (SnapshotRead), then computes outside it. A query fired from in here
    # would run outside that snapshot and could see a different state of the
    # ledger, so the answer would match no real state of the books. This is
    # the assertion that keeps that from happening quietly.
    it 'runs none, given meals with the three associations preloaded' do
      cook = resident('Cook')
      host = resident('Host')

      meals = Array.new(3) do
        meal = create(:meal, community: community)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
        create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
        create(:meal_resident, meal: meal, resident: host, community: community, multiplier: 2)
        create(:guest, meal: meal, resident: host, multiplier: 2)
        meal
      end

      ledger = ledger_for(*meals)

      queries = count_queries do
        ledger.lines
        ledger.balances([cook.id, host.id])
      end

      expect(queries).to eq(0)
    end
  end
end
