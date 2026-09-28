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
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)

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
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)

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
      create(:meal_resident, meal: meal, resident: cook, community: community)

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
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: helper, community: community)

      credits = ledger_for(meal).lines.select { |line| line.kind == :credit }

      expect(credits.map(&:resident_id)).to eq([cook.id])
    end

    it 'charges a guest to the resident who brought them' do
      cook = resident('Cook')
      host = resident('Host')

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: host, community: community)
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
      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)

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
      create(:meal_resident, meal: meal, resident: cook_a, community: community)
      create(:meal_resident, meal: meal, resident: cook_b, community: community)

      credits = ledger_for(meal).lines.select { |line| line.kind == :credit }
      by_resident = credits.to_h { |line| [line.resident_id, line.amount] }

      # 4 units of multiplier * 4.50 = 18.00 charged, against 60.00 spent.
      # 18.00 split 40:20 is 12 and 6, whole units with nothing left over.
      # 'shares a subsidized credit at the ledger grain' below has a
      # leftover unit.
      expect(by_resident).to eq(cook_a.id => BigDecimal('12'), cook_b.id => BigDecimal('6'))
    end

    it 'makes every amount zero on a meal whose attendees all have multiplier zero' do
      cook = resident('Cook')
      baby = resident('Baby', multiplier: 0)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      create(:meal_resident, meal: meal, resident: baby, community: community)

      ledger = ledger_for(meal)

      # The zero lines exist: a settlement stores them, and a settled meal's
      # screen reads them (MealCostSummary). `all` alone passes on no lines.
      expect(ledger.lines.map { |line| [line.kind, line.resident_id] })
        .to contain_exactly([:credit, cook.id], [:debit, baby.id])
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
      children.each { |child| create(:meal_resident, meal: meal, resident: child, community: community) }

      lines = ledger_for(meal).lines
      debits = lines.select { |line| line.kind == :debit }

      expect(debits.map(&:amount)).to all(eq(BigDecimal('-26.585')))
      expect(debits.map(&:unit_cost)).to all(eq(BigDecimal('26.585')))
      expect(lines.sum(BigDecimal('0'), &:amount)).to eq(BigDecimal('0'))
    end

    it 'shares a subsidized credit at the ledger grain, the leftover unit to the lowest resident id' do
      community.update!(cap: BigDecimal('0.50'))
      cooks = %w[A B C].map { |name| resident("Cook #{name}") }
      eater = resident('Eater')

      # 2 units of multiplier * 0.50 = 1.00 charged, against 3.00 spent.
      # 1.00 across three cooks who spent the same: 0.33333334 and two
      # 0.33333333, and the three sum to exactly what the eater is charged.
      meal = create(:meal, community: community)
      cooks.each { |cook| create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1')) }
      create(:meal_resident, meal: meal, resident: eater, community: community)

      lines = ledger_for(meal).lines
      credits = lines.select { |line| line.kind == :credit }.sort_by(&:resident_id)

      expect(credits.map(&:amount)).to eq([BigDecimal('0.33333334'), BigDecimal('0.33333333'),
                                           BigDecimal('0.33333333')])
      expect(lines.sum(BigDecimal('0'), &:amount)).to eq(BigDecimal('0'))
    end

    it 'carries the multiplier on a debit and leaves it off a credit' do
      cook = resident('Cook')
      child = resident('Child', multiplier: 1)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: child, community: community)

      lines = ledger_for(meal).lines

      expect(lines.find { |line| line.kind == :debit }.multiplier).to eq(1)
      expect(lines.find { |line| line.kind == :credit }.multiplier).to be_nil
      expect(lines.find { |line| line.kind == :debit }.bill_amount).to be_nil
    end
  end

  # The grain: every line is a whole number of units of 10^-8 dollars,
  # shares are allocated, and a meal's lines sum to exactly zero (MODELS.md,
  # "The ledger grain"; ADR 0008; #85).
  describe 'the ledger grain' do
    it 'charges the worked example in MODELS.md: the leftover unit goes to the lowest resident id' do
      cook = resident('Cook')
      adults = %w[One Two Three].map { |name| resident("Adult #{name}") }
      child = resident('Child', multiplier: 1)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      (adults + [child]).each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }

      lines = ledger_for(meal).lines
      debits = lines.select { |line| line.kind == :debit }.sort_by(&:resident_id)

      expect(debits.map(&:amount)).to eq([BigDecimal('-17.14285715'), BigDecimal('-17.14285714'),
                                          BigDecimal('-17.14285714'), BigDecimal('-8.57142857')])
      expect(debits.map(&:unit_cost)).to all(eq(BigDecimal('8.57142857')))
      expect(lines.sum(BigDecimal('0'), &:amount)).to eq(BigDecimal('0'))
    end

    it 'puts an attendee line before a guest line of the same resident in the tie order' do
      cook = resident('Cook')
      host = resident('Host', multiplier: 1)
      other = resident('Other', multiplier: 1)

      # $1.00 across three units: one leftover unit, and the host has the
      # lowest resident id twice over, once as an attendee and once as a
      # guest's host. The attendee line gets it.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      create(:meal_resident, meal: meal, resident: other, community: community)
      guest = create(:guest, meal: meal, resident: host, multiplier: 1)
      # The two rows are in different tables, so their ids come from
      # different sequences. The host's attendance row gets an id above
      # the guest's on purpose: ordered by row id alone, the guest line
      # would come first and get the leftover unit.
      create(:meal_resident, meal: meal, resident: host, community: community,
                             id: [MealResident.maximum(:id), guest.id].max + 1)

      debits = ledger_for(meal).lines.reject { |line| line.kind == :credit }
      by_kind = debits.to_h { |line| [[line.resident_id, line.kind], line.amount] }

      expect(by_kind).to eq(
        [host.id, :debit] => BigDecimal('-0.33333334'),
        [host.id, :guest_debit] => BigDecimal('-0.33333333'),
        [other.id, :debit] => BigDecimal('-0.33333333')
      )
    end

    # This rule only makes the order fixed. It moves no money: both guest
    # lines charge the same host, and a line carries no guest id. So the
    # guests have different multipliers, and the order is read off the
    # multiplier each line carries.
    it 'puts the lower guest id first between two guests of one host' do
      cook = resident('Cook')
      host = resident('Host', multiplier: 0)
      other = resident('Other', multiplier: 1)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      create(:meal_resident, meal: meal, resident: host, community: community)
      create(:meal_resident, meal: meal, resident: other, community: community)
      first_guest = create(:guest, meal: meal, resident: host, multiplier: 2)
      second_guest = create(:guest, meal: meal, resident: host, multiplier: 1)

      # The guests are loaded highest id first, so a sort that ignored the
      # guest id and kept the order it was given would put them the wrong
      # way round.
      loaded = Meal.where(id: meal.id).preload(:bills, :meal_residents).eager_load(:guests)
                   .order('guests.id DESC').to_a
      expect(loaded.first.guests.map(&:id)).to eq([second_guest.id, first_guest.id])
      ledger = described_class.new(loaded)
      guest_lines = ledger.lines.select { |line| line.kind == :guest_debit }

      expect(first_guest.id).to be < second_guest.id
      expect(guest_lines.map(&:multiplier)).to eq([2, 1])
      expect(guest_lines.map(&:amount)).to eq([BigDecimal('-0.5'), BigDecimal('-0.25')])
      expect(ledger.lines.find { |line| line.kind == :debit && line.resident_id == host.id }.amount)
        .to eq(BigDecimal('0'))
    end

    # $2 across 3 units of multiplier is 0.666666666...: cut to the grain it
    # is 0.66666666, and rounded it would be 0.66666667.
    it 'cuts the unit cost a screen shows to the grain' do
      cook = resident('Cook')
      eaters = %w[A B C].map { |name| resident("Eater #{name}", multiplier: 1) }

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('2'))
      eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }

      summary = ledger_for(meal).summary_for(meal)

      expect(summary.unit_cost).to eq(BigDecimal('0.66666666'))
      expect(summary.effective_cost).to eq(BigDecimal('2'))
    end

    it 'refuses an amount that is not a whole number of units' do
      expect { described_class.units(BigDecimal('0.000000001')) }
        .to raise_error(ArgumentError, /not a whole number of 10\^-8 dollars/)
      expect(described_class.units(BigDecimal('12.34'))).to eq(1_234_000_000)
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
        create(:meal_resident, meal: meal, resident: cook, community: community)
        create(:meal_resident, meal: meal, resident: host, community: community)
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
