# frozen_string_literal: true

require 'rails_helper'

# The audit sentences the meal history modal shows. Moved from
# ApplicationHelper's parse_audit (#51).
RSpec.describe AuditDescription do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }
  let(:name) { ResidentNameShortener.short(resident.name) }

  it 'parses meal create audit' do
    audit = meal.audits.first
    expect(described_class.describe(audit)).to eq('Meal record created')
  end

  it 'parses meal closed audit' do
    meal.update!(closed: true)
    audit = meal.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq('Meal closed')
  end

  it 'parses meal opened audit' do
    meal.update!(closed: true)
    meal.update!(closed: false)
    audit = meal.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq('Meal opened')
  end

  it 'parses description update audit' do
    meal.update!(description: 'Pasta night')
    audit = meal.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq('Menu description updated')
  end

  it 'parses bill create audit' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    audit = bill.audits.first
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("#{name} added as cook")
  end

  it 'parses bill amount change audit' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    bill.update!(amount: BigDecimal('50'))
    audit = bill.audits.where(action: 'update').last
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $50.00")
  end

  it 'parses bill no_cost toggled on audit' do
    bill = create(:bill, meal: meal, resident: resident, community: community,
                         amount: BigDecimal('0'), no_cost: false)
    bill.update!(no_cost: true)
    audit = bill.audits.where(action: 'update').last
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} marked as no cost")
  end

  it 'parses bill no_cost toggled off audit' do
    bill = create(:bill, meal: meal, resident: resident, community: community,
                         amount: BigDecimal('0'), no_cost: true)
    bill.update!(no_cost: false)
    audit = bill.audits.where(action: 'update').last
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} no longer marked as no cost")
  end

  it 'parses simultaneous amount and no_cost change audit' do
    bill = create(:bill, meal: meal, resident: resident, community: community,
                         amount: BigDecimal('30'), no_cost: false)
    bill.update!(amount: BigDecimal('0'), no_cost: true)
    audit = bill.audits.where(action: 'update').last
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $0.00 and marked as no cost")
  end

  # Until migration 20260326000001, bills.amount was called amount_cents
  # and held whole cents. The audit rows written before it still hold
  # amount_cents: 6051 of them in production, from 2017-08-30 to
  # 2026-03-24. The history once said "unknown bill changed" for each.
  describe 'bill rows from before the amount was in dollars' do # -- a group of cases, not a method
    # Stored, as the old rows are: a row names its cook through the rows
    # before it in the bill's own history.
    def cents_row(bill_id, cents)
      Audited::Audit.create!(auditable_type: 'Bill', auditable_id: bill_id, action: 'update',
                             audited_changes: { 'amount_cents' => cents })
    end

    let(:bill) { create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('72.06')) }

    it 'says whose bill changed, and from what to what, in dollars' do
      rows = [[7200, 7206], [0, 400], [400, 1], [1, 8_674_900]].map { |cents| cents_row(bill.id, cents) }
      describer = described_class.for(rows)

      expect(rows.map { |row| describer.describe(row) }).to eq(
        ["Bill for #{name} changed from $72.00 to $72.06", "Bill for #{name} changed from $0.00 to $4.00",
         "Bill for #{name} changed from $4.00 to $0.01", "Bill for #{name} changed from $0.01 to $86,749.00"]
      )
    end

    # The create rows of that time hold amount_cents too, and name the
    # cook the same way.
    it 'names the cook of a bill that is gone from its old create row' do
      Audited::Audit.create!(auditable_type: 'Bill', auditable_id: 999_999, action: 'create',
                             audited_changes: { 'meal_id' => meal.id, 'resident_id' => resident.id,
                                                'amount_cents' => 0, 'amount_currency' => 'USD' })

      expect(described_class.describe(cents_row(999_999, [0, 3648])))
        .to eq("Bill for #{name} changed from $0.00 to $36.48")
    end

    # The column was a NOT NULL integer, so no real row holds anything
    # else. The history still answers, because a history that raises
    # shows nothing at all.
    it 'says a bill changed in an unknown way when the old amounts are not whole numbers of cents' do
      rows = [[nil, 400], %w[7200 7206], [72.5, 80], 7200].map { |cents| cents_row(bill.id, cents) }
      describer = described_class.for(rows)

      expect(rows.map { |row| describer.describe(row) }).to all(eq('unknown bill changed'))
    end
  end

  # Before April 2026 the meal page let a cost be typed into a row marked
  # No cost, and MealLedger leaves a no-cost bill out of the meal's cost.
  # Migration 20261010130000 turned No cost off on those bills, and wrote
  # one row for each: no_cost [true, false], and nothing about the amount,
  # because the amount did not change. The history reads the amount from
  # the bill's own rows, the way it reads the cook. Nothing can make such a
  # bill now (Bill::NO_COST_MEANS_NO_AMOUNT), so the rows are written by
  # hand, the way they are stored.
  describe 'a row that turns No cost off on a bill with an amount' do # -- a group of cases, not a method
    def row(bill_id, action, changes, username: nil, comment: nil)
      Audited::Audit.create!(auditable_type: 'Bill', auditable_id: bill_id, associated_type: 'Meal',
                             associated_id: meal.id, action: action, audited_changes: changes, username: username,
                             comment: comment)
    end

    it 'says the amount now counts in the meal cost' do
      row(999_990, 'create', { 'meal_id' => meal.id, 'resident_id' => resident.id, 'amount' => '0.0',
                               'no_cost' => true })
      row(999_990, 'update', { 'amount' => ['0.0', '86.0'] })
      fix = row(999_990, 'update', { 'no_cost' => [true, false] }, username: 'Automatic fix')

      expect(described_class.describe(fix))
        .to eq("Bill for #{name} no longer marked as no cost, so the $86.00 now counts in the meal's cost")
    end

    # The 27 bills in the production copy of September 2026 were all typed
    # before the amount was in dollars, so their rows hold amount_cents.
    it 'reads an amount typed in cents, and the last of several' do
      row(999_991, 'create', { 'meal_id' => meal.id, 'resident_id' => resident.id, 'no_cost' => false,
                               'amount_cents' => 0, 'amount_currency' => 'USD' })
      row(999_991, 'update', { 'no_cost' => [false, true] })
      row(999_991, 'update', { 'amount_cents' => [0, 300] })
      row(999_991, 'update', { 'amount_cents' => [300, 3550] })
      fix = row(999_991, 'update', { 'no_cost' => [true, false] })

      expect(described_class.describe(fix))
        .to eq("Bill for #{name} no longer marked as no cost, so the $35.50 now counts in the meal's cost")
    end

    it 'says nothing about an amount of $0, or an amount the history does not hold' do
      row(999_992, 'create', { 'meal_id' => meal.id, 'resident_id' => resident.id, 'amount' => '0.0',
                               'no_cost' => true })
      zero = row(999_992, 'update', { 'no_cost' => [true, false] })
      unknown = row(999_993, 'update', { 'no_cost' => [true, false] })
      describer = described_class.for([zero, unknown])

      expect(describer.describe(zero)).to eq("Bill for #{name} no longer marked as no cost")
      expect(describer.describe(unknown)).to eq('Bill for unknown no longer marked as no cost')
    end
  end

  # Until 2026-10-10 the admin bill form could change a bill's cook in
  # place. Production holds three such rows, all on bill 1995 (meal 1356,
  # 2023-03-05): Sandra to Sarah, back to Sandra, and to Sarah again,
  # after which the bill was deleted. The history said "unknown bill
  # changed" for each. Nothing can write such a row now
  # (Bill::COOK_AND_MEAL_FIXED), so these are written by hand, the way
  # they are stored.
  describe 'bills whose cook was changed in place' do # -- a group of cases, not a method
    let(:ann) { create(:resident, community: community, unit: unit) }
    let(:bob) { create(:resident, community: community, unit: unit) }

    def short(person)
      ResidentNameShortener.short(person.name)
    end

    def old_row(bill_id, action, changes)
      Audited::Audit.create!(auditable_type: 'Bill', auditable_id: bill_id, associated_type: 'Meal',
                             associated_id: meal.id, action: action, audited_changes: changes)
    end

    # Bill 1995's history, with other names, and one more cost change
    # after the moves, so a line after a move has a cook to name.
    def moved_bill_history(bill_id)
      old_row(bill_id, 'create', { 'meal_id' => meal.id, 'resident_id' => ann.id, 'amount_cents' => 0 })
      old_row(bill_id, 'update', { 'amount_cents' => [0, 350] })
      [[ann, bob], [bob, ann], [ann, bob]].each do |from, to|
        old_row(bill_id, 'update', { 'resident_id' => [from.id, to.id] })
      end
      old_row(bill_id, 'update', { 'amount_cents' => [350, 358] })
      old_row(bill_id, 'destroy', { 'meal_id' => meal.id, 'resident_id' => bob.id, 'amount_cents' => 358 })
      Audited::Audit.where(auditable_type: 'Bill', auditable_id: bill_id).order(:version).to_a
    end

    it 'says the bill moved, with both names, and names each cost line by the cook it was about' do
      rows = moved_bill_history(999_995)
      describer = described_class.for(rows)
      expected = ["#{short(ann)} added as cook", "Bill for #{short(ann)} changed from $0.00 to $3.50",
                  "Bill moved from #{short(ann)} to #{short(bob)}", "Bill moved from #{short(bob)} to #{short(ann)}",
                  "Bill moved from #{short(ann)} to #{short(bob)}",
                  "Bill for #{short(bob)} changed from $3.50 to $3.58", "#{short(bob)} removed as cook"]

      expect(rows.map { |row| describer.describe(row) }).to eq(expected)
      # One describer per row repeats its reads on purpose: it is the
      # same answer reached one row at a time.
      expect(Prosopite.pause { rows.map { |row| described_class.describe(row) } }).to eq(expected)
    end

    it 'says what else changed when one save moved the bill' do
      old_row(999_996, 'create', { 'meal_id' => meal.id, 'resident_id' => ann.id, 'amount' => '0.0' })
      cost = old_row(999_996, 'update', { 'resident_id' => [ann.id, bob.id], 'amount' => ['0.0', '12.0'] })
      flag = old_row(999_996, 'update', { 'resident_id' => [bob.id, ann.id], 'no_cost' => [false, true] })

      describer = described_class.for([cost, flag])

      expect([cost, flag].map { |row| describer.describe(row) }).to eq(
        ["Bill moved from #{short(ann)} to #{short(bob)} and changed from $0.00 to $12.00",
         "Bill moved from #{short(bob)} to #{short(ann)} and marked as no cost"]
      )
    end

    it 'names an unknown cook on either side when that resident is gone' do
      row = old_row(999_997, 'update', { 'resident_id' => [ann.id, 999_999] })

      expect(described_class.describe(row)).to eq("Bill moved from #{short(ann)} to unknown")
    end
  end

  # No path in the app changes the person on an attendance row: the API
  # changes only late and vegetarian, and admin only adds and removes
  # rows. The model does not refuse it, though, and three production
  # rows did it (attendance row 8756, meal 1356, 2023-03-05: Sandra to
  # Arlen, back to Sandra, and to Arlen again). The history said
  # "MealResident, update" for each.
  describe 'attendance rows whose person was changed' do # -- a group of cases, not a method
    let(:ann) { create(:resident, community: community, unit: unit) }
    let(:bob) { create(:resident, community: community, unit: unit) }

    def short(person)
      ResidentNameShortener.short(person.name)
    end

    it 'says the sign-up moved, with both names, and names each other line by the person it was about' do
      attendance = create(:meal_resident, meal: meal, resident: ann, community: community, late: false)
      attendance.update!(late: true)
      [bob, ann, bob].each { |person| attendance.update!(resident: person) }
      attendance.update!(late: false)
      rows = attendance.audits.order(:version).to_a
      describer = described_class.for(rows)

      expect(rows.map { |row| describer.describe(row) }).to eq(
        ["#{short(ann)} added", "#{short(ann)} marked late", "Sign-up moved from #{short(ann)} to #{short(bob)}",
         "Sign-up moved from #{short(bob)} to #{short(ann)}", "Sign-up moved from #{short(ann)} to #{short(bob)}",
         "#{short(bob)} marked not late"]
      )
    end

    it 'says the price changed too when one save moved the sign-up and changed its price' do
      attendance = create(:meal_resident, meal: meal, resident: ann, community: community)
      row = Audited::Audit.create!(auditable: attendance, action: 'update',
                                   audited_changes: { 'resident_id' => [ann.id, bob.id], 'multiplier' => [2, 1] })

      expect(described_class.describe(row)).to eq("Sign-up moved from #{short(ann)} to #{short(bob)}: Adult to Child")
    end
  end

  it 'resolves resident name for a bill update audit from the create audit once the bill is gone' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    bill.update!(amount: BigDecimal('50'))
    audit = bill.audits.where(action: 'update').last
    bill.destroy!
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $50.00")
  end

  it 'describes a whole list with the lookups done once, and the same words as one row at a time' do
    other = create(:resident, community: community, unit: unit)
    attendance = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
    attendance.update!(late: true)
    gone = create(:meal_resident, meal: meal, resident: other, community: community, late: false)
    gone.update!(late: true)
    gone.destroy!
    bill = create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('30'))
    bill.update!(amount: BigDecimal('50'))
    guest = create(:guest, meal: meal, resident: resident)
    guest.update!(multiplier: Multiplier::HALF)
    guest.update!(resident: other)
    rows = meal.total_audits
    # One describer per row is the repeat this spec exists to rule out,
    # so it is not scanned here; it is the yardstick the list is checked
    # against.
    one_at_a_time = Prosopite.pause { rows.map { |row| described_class.describe(row) } }

    describer = described_class.for(rows)
    together = count_queries { rows.map { |row| describer.describe(row) } }

    expect(together).to eq(0)
    expect(rows.map { |row| describer.describe(row) }).to eq(one_at_a_time)
    other_name = ResidentNameShortener.short(other.name)
    expect(one_at_a_time).to include("#{name} marked late", "#{other_name} removed",
                                     "Guest of #{name}: Adult to Child", "Guest of #{name} moved to #{other_name}")
  end

  it 'resolves resident name for bill destroy audit after bill is deleted' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    bill.destroy!
    destroy_audit = Audited::Audit.find_by(auditable_type: 'Bill', auditable_id: bill.id, action: 'destroy')
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(destroy_audit)).to eq("#{name} removed as cook")
  end

  it 'resolves resident name for bill create audit after bill is later deleted' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    create_audit = bill.audits.where(action: 'create').first
    bill.destroy!
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(create_audit)).to eq("#{name} added as cook")
  end

  it 'resolves resident name for meal_resident update audit after record is deleted' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
    mr.update!(late: true)
    update_audit = mr.audits.where(action: 'update').last
    mr.destroy!
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(update_audit)).to include("#{name} marked late")
  end

  it 'parses meal_resident create audit' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community)
    audit = mr.audits.first
    expect(described_class.describe(audit)).to eq("#{name} added")
  end

  it 'parses meal_resident destroy audit' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community)
    mr.destroy!
    expect(described_class.describe(mr.audits.where(action: 'destroy').last)).to eq("#{name} removed")
  end

  it 'parses meal_resident marked late audit' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
    mr.update!(late: true)
    audit = mr.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq("#{name} marked late")

    mr.update!(late: false)
    audit = mr.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq("#{name} marked not late")
  end

  it 'parses meal_resident vegetarian toggle audits' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community, vegetarian: false)
    mr.update!(vegetarian: true)
    audit = mr.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq("#{name} marked veg")

    mr.update!(vegetarian: false)
    audit = mr.audits.where(action: 'update').last
    expect(described_class.describe(audit)).to eq("#{name} marked not veg")
  end

  it 'parses guest create audit' do
    guest = create(:guest, meal: meal, resident: resident, vegetarian: false)
    expect(described_class.describe(guest.audits.first)).to eq("Omnivore guest of #{name} added")
  end

  it 'parses vegetarian guest create audit' do
    guest = create(:guest, meal: meal, resident: resident, vegetarian: true)
    expect(described_class.describe(guest.audits.first)).to eq("Veg guest of #{name} added")
  end

  it 'parses guest destroy audits, veg and not' do
    veg = create(:guest, meal: meal, resident: resident, vegetarian: true)
    omni = create(:guest, meal: meal, resident: resident, vegetarian: false)
    veg.destroy!
    omni.destroy!
    expect(described_class.describe(veg.audits.where(action: 'destroy').last)).to eq("Veg guest of #{name} removed")
    expect(described_class.describe(omni.audits.where(action: 'destroy').last))
      .to eq("Omnivore guest of #{name} removed")
  end

  # A price change or a new host once read "MealResident, update" or
  # "Guest, update", which named neither the person nor the change. The
  # price words are the ones every admin page uses (Multiplier.label).
  describe 'price and host changes' do # -- a group of cases, not a method
    let(:ann) { create(:resident, community: community, unit: unit) }
    let(:bob) { create(:resident, community: community, unit: unit) }

    def short(person)
      ResidentNameShortener.short(person.name)
    end

    def update_rows(record)
      record.audits.where(action: 'update').order(:version).to_a
    end

    # The one path in the app that changes a resident's price: an admin
    # moves the meal to a day on which Sam has turned 12
    # (Meal#restamp_attendance_for_new_date).
    it 'says whose price changed, and from what to what, when a meal moves past a birthday' do
      moving = create(:meal, community: community, date: Date.new(2026, 11, 5))
      sam = create(:resident, community: community, unit: unit, birthday: Date.new(2014, 11, 6))
      attendance = create(:meal_resident, meal: moving, resident: sam, community: community)

      moving.update!(date: Date.new(2026, 11, 6))

      expect(described_class.describe(update_rows(attendance).last)).to eq("#{short(sam)}: Child to Adult")
    end

    it 'says a guest moved from one host to another' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(resident: bob)

      expect(described_class.describe(update_rows(guest).last)).to eq("Guest of #{short(ann)} moved to #{short(bob)}")
    end

    it 'says whose guest changed price, and from what to what' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)

      expect(described_class.describe(update_rows(guest).last)).to eq("Guest of #{short(ann)}: Adult to Child")
    end

    it 'says both when one save changed the host and the price' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(resident: bob, multiplier: Multiplier::HALF)

      expect(described_class.describe(update_rows(guest).last))
        .to eq("Guest of #{short(ann)} moved to #{short(bob)}: Adult to Child")
    end

    # The host is the one the guest had when the row was written, read
    # from the guest's own history. The guest as it is now would put
    # Bob's name on a price change made while Ann was the host.
    it 'names the host a guest had when its price changed, not the host it has now' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)
      guest.update!(resident: bob)
      guest.update!(multiplier: Multiplier::FULL)
      rows = update_rows(guest)
      describer = described_class.for(rows)
      expected = ["Guest of #{short(ann)}: Adult to Child", "Guest of #{short(ann)} moved to #{short(bob)}",
                  "Guest of #{short(bob)}: Child to Adult"]

      expect(rows.map { |row| describer.describe(row) }).to eq(expected)
      # One describer per row repeats its reads on purpose: it is the
      # same answer reached one row at a time.
      expect(Prosopite.pause { rows.map { |row| described_class.describe(row) } }).to eq(expected)
    end

    it 'names the host of a guest that is gone' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)
      row = update_rows(guest).last
      guest.destroy!

      expect(described_class.describe(row)).to eq("Guest of #{short(ann)}: Adult to Child")
    end

    # Every guest has a create row: the app has audited guests from the
    # start. One written outside the app would not, and then the history
    # cannot say who the host was.
    it 'names an unknown host when the history has no create row for the guest' do
      row = instance_double(Audited::Audit, id: 999_998, auditable_type: 'Guest', action: 'update',
                                            auditable_id: 999_999, audited_changes: { 'multiplier' => [2, 1] })

      expect(described_class.describe(row)).to eq('Guest of unknown: Adult to Child')
    end

    it "names an unknown host when the guest's create row is gone and only its later rows are left" do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)
      guest.audits.where(action: 'create').delete_all

      expect(described_class.describe(update_rows(guest).last)).to eq('Guest of unknown: Adult to Child')
    end

    # The ids of two tables often match. This attendance row has the
    # guest's id, and its person changes between the guest's two price
    # changes. Read with the guest's history, that change would look like
    # a new host for the guest.
    it 'reads only the guest history, not the history of an attendance row with the same id' do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)
      guest.update!(multiplier: Multiplier::FULL)
      attendance = create(:meal_resident, id: guest.id, meal: meal, resident: bob, community: community)
      attendance.update!(resident: create(:resident, community: community, unit: unit))

      expect(described_class.describe(update_rows(guest).last)).to eq("Guest of #{short(ann)}: Child to Adult")
    end

    # Each row's host is the host before it, so the history has to be
    # read in order. PostgreSQL often returns these rows in that order
    # without being asked, so no set of rows can show that it was asked.
    # This reads the statement instead. Two rows of one record can share a
    # version, so the id breaks the tie.
    it "asks for each guest's history in version order, then id" do
      guest = create(:guest, meal: meal, resident: ann)
      guest.update!(multiplier: Multiplier::HALF)
      rows = update_rows(guest)
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { described_class.for(rows) }

      expect(statements.grep(/FROM "audits"/))
        .to contain_exactly(/ ORDER BY "audits"\."version" ASC, "audits"\."id" ASC\z/)
    end

    it 'names an unknown host when the resident is gone' do
      row = instance_double(Audited::Audit, auditable_type: 'Guest', action: 'update', auditable_id: 999_999,
                                            audited_changes: { 'resident_id' => [ann.id, 999_999] })

      expect(described_class.describe(row)).to eq("Guest of #{short(ann)} moved to unknown")
    end

    it "reads every guest's history in one query, however many guests and rows there are" do
      2.times do
        guest = create(:guest, meal: meal, resident: ann)
        guest.update!(multiplier: Multiplier::HALF)
        guest.update!(resident: bob)
      end
      rows = Audited::Audit.where(auditable_type: 'Guest', action: 'update').to_a

      # The guests' histories and the residents.
      expect(count_queries { described_class.for(rows) }).to eq(2)
    end
  end

  describe 'the less common meal changes' do # -- a group of cases, not a method
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit) }
    # max only holds on a closed meal (Meal#conditionally_set_max).
    let(:meal) { create(:meal, community: community, closed: true, max: nil) }

    def last_update_audit(record)
      record.audits.where(action: 'update').last
    end

    it 'says the extras count was set the first time' do
      meal.update!(max: 4)
      expect(described_class.describe(last_update_audit(meal))).to eq('Extras count set')
    end

    it 'says the extras count was cleared' do
      meal.update!(max: 4)
      meal.update!(max: nil)
      expect(described_class.describe(last_update_audit(meal))).to eq('Extras count cleared')
    end

    it 'says by how much the extras count went up' do
      meal.update!(max: 4)
      meal.update!(max: 7)
      expect(described_class.describe(last_update_audit(meal))).to eq('Extras count increased by 3')
    end

    it 'says by how much the extras count went down' do
      meal.update!(max: 7)
      meal.update!(max: 2)
      expect(described_class.describe(last_update_audit(meal))).to eq('Extras count decreased by 5')
    end

    it 'says the meal was assigned to a rotation' do
      rotation = create(:rotation, community: community)
      meal.update!(rotation: rotation)
      expect(described_class.describe(last_update_audit(meal))).to eq('Meal assigned to a rotation')
    end

    it 'falls back to the type and action for a meal change it does not recognize' do
      audit = instance_double(Audited::Audit, auditable_type: 'Meal', action: 'update',
                                              audited_changes: { 'start_time' => [nil, '18:00'] })
      expect(described_class.describe(audit)).to eq('Meal, update')
    end

    it 'falls back for a closed change with no true on either side' do
      audit = instance_double(Audited::Audit, auditable_type: 'Meal', action: 'update',
                                              audited_changes: { 'closed' => [nil, false] })
      expect(described_class.describe(audit)).to eq('Meal, update')
    end

    it 'says a bill changed in an unknown way when neither amount nor no_cost moved' do
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      audit = instance_double(Audited::Audit, id: nil, auditable_type: 'Bill', action: 'update',
                                              auditable_id: bill.id, audited_changes: { 'updated_at' => [1, 2] })
      expect(described_class.describe(audit)).to eq('unknown bill changed')
    end

    it 'falls back for a meal_resident late change with no clear direction' do
      open_meal = create(:meal, community: community, date: meal.date + 1)
      meal_resident = create(:meal_resident, meal: open_meal, resident: resident, community: community)
      audit = instance_double(Audited::Audit, id: nil, auditable_type: 'MealResident', action: 'update',
                                              auditable_id: meal_resident.id,
                                              audited_changes: { 'late' => [nil, nil] })
      expect(described_class.describe(audit)).to eq('MealResident, update')
    end

    it 'falls back for a record type it has never heard of' do
      audit = instance_double(Audited::Audit, auditable_type: 'Rotation', action: 'update', audited_changes: {})
      expect(described_class.describe(audit)).to eq('Rotation, update')
    end

    # Only a guest row is read as a guest. A created row of another type
    # that carries a vegetarian flag, as a resident's does, is not one.
    it 'does not read a created row of another type as a guest' do
      audit = instance_double(Audited::Audit, auditable_type: 'Resident', action: 'create', auditable_id: 1,
                                              audited_changes: { 'vegetarian' => true })
      expect(described_class.describe(audit)).to eq('Resident, create')
    end
  end

  # The audited gem writes create, update and destroy. The parser still has
  # an answer for a row with any other action, or with a change it cannot
  # read, because a history modal that raises shows nothing at all.
  describe 'rows the parser cannot read' do
    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }
    let(:resident) { create(:resident, community: community, unit: unit) }
    let(:meal) { create(:meal, community: community, closed: true, max: nil) }
    let(:name) { ResidentNameShortener.short(resident.name) }

    # A row that is not stored, so it has no id, and the history of its
    # record does not hold it.
    def audit(type, action, changes, id: nil)
      instance_double(Audited::Audit, id: nil, auditable_type: type, action: action, audited_changes: changes,
                                      auditable_id: id)
    end

    it 'says a meal was deleted' do
      open_meal = create(:meal, community: community, date: meal.date + 1)
      open_meal.destroy!
      deleted = Audited::Audit.find_by(auditable_type: 'Meal', auditable_id: open_meal.id, action: 'destroy')
      expect(described_class.describe(deleted)).to eq('Meal record deleted')
    end

    it 'falls back for a meal row with an action it does not know' do
      expect(described_class.describe(audit('Meal', 'touch', {}))).to eq('Meal, touch')
    end

    it 'says the extras count was set when the row records the same count twice' do
      expect(described_class.describe(audit('Meal', 'update', { 'max' => [4, 4] }))).to eq('Extras count set')
    end

    it 'names an unknown cook when the resident on a bill row is gone' do
      row = audit('Bill', 'create', { 'resident_id' => 999_999, 'amount' => '30.0' })
      expect(described_class.describe(row)).to eq('unknown added as cook')
    end

    it 'names an unknown cook when the bill and its create audit are both gone' do
      row = audit('Bill', 'update', { 'amount' => ['30.0', '50.0'] }, id: 999_999)
      expect(described_class.describe(row)).to eq('Bill for unknown changed from $30.00 to $50.00')
    end

    it 'says a bill is no longer no-cost when the amount changed at the same time' do
      bill = create(:bill, meal: meal, resident: resident, community: community,
                           amount: BigDecimal('0'), no_cost: true)
      bill.update!(amount: BigDecimal('12'), no_cost: false)
      row = bill.audits.where(action: 'update').last
      expect(described_class.describe(row))
        .to eq("Bill for #{name} changed from $0.00 to $12.00 and no longer marked as no cost")
    end

    it 'falls back for a bill row with an action it does not know' do
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      row = audit('Bill', 'touch', { 'amount' => ['30.0', '50.0'] }, id: bill.id)
      expect(described_class.describe(row)).to eq('Bill, touch')
    end

    describe 'attendance rows' do
      let(:open_meal) { create(:meal, community: community, date: meal.date + 1) }
      let(:attendance) { create(:meal_resident, meal: open_meal, resident: resident, community: community) }

      it 'says who was removed' do
        attendance.destroy!
        row = Audited::Audit.find_by(auditable_type: 'MealResident', auditable_id: attendance.id, action: 'destroy')
        expect(described_class.describe(row)).to eq("#{name} removed")
      end

      it 'names an unknown person when the attendance row and its create audit are both gone' do
        row = audit('MealResident', 'update', { 'multiplier' => [2, 1] }, id: 999_999)
        expect(described_class.describe(row)).to eq('unknown: Adult to Child')
      end

      it 'says who is no longer late' do
        attendance.update!(late: true)
        attendance.update!(late: false)
        row = attendance.audits.where(action: 'update').last
        expect(described_class.describe(row)).to eq("#{name} marked not late")
      end

      it 'falls back for a vegetarian change with no clear direction' do
        row = audit('MealResident', 'update', { 'vegetarian' => [nil, nil] }, id: attendance.id)
        expect(described_class.describe(row)).to eq('MealResident, update')
      end

      # A change that starts and ends the same way has no direction either:
      # neither "marked veg" nor "marked not veg" is true of it.
      it 'falls back for a change from true to true, or false to false' do
        rows = [%w[late vegetarian], [[true, true], [false, false]]].then do |fields, changes|
          fields.product(changes).map do |field, change|
            audit('MealResident', 'update', { field => change }, id: attendance.id)
          end
        end
        describer = described_class.for(rows)
        expect(rows.map { |row| describer.describe(row) }).to all(eq('MealResident, update'))
      end

      it 'falls back for an update that touched none of late, vegetarian and the price' do
        row = audit('MealResident', 'update', { 'updated_at' => [1, 2] }, id: attendance.id)
        expect(described_class.describe(row)).to eq('MealResident, update')
      end

      # The column refuses a nil, so no real row holds one. The history
      # still answers, because a history that raises shows nothing at all.
      it 'falls back for a price change that is not two whole numbers' do
        rows = [[nil, 2], %w[2 1]].map do |change|
          audit('MealResident', 'update', { 'multiplier' => change }, id: attendance.id)
        end
        describer = described_class.for(rows)
        expect(rows.map { |row| describer.describe(row) }).to all(eq('MealResident, update'))
      end

      # Stored, so the row's place in the attendance row's history names
      # the person.
      it 'names a free child by the words the admin pages use' do
        row = Audited::Audit.create!(auditable: attendance, action: 'update',
                                     audited_changes: { 'multiplier' => [0, 1] })
        expect(described_class.describe(row)).to eq("#{name}: Child (free) to Child")
      end

      it 'falls back for an action it does not know' do
        row = audit('MealResident', 'touch', { 'resident_id' => resident.id }, id: attendance.id)
        expect(described_class.describe(row)).to eq('MealResident, touch')
      end
    end

    describe 'guest rows' do
      it 'falls back for a vegetarian change, which nothing in the app writes' do
        row = audit('Guest', 'update', { 'resident_id' => resident.id, 'vegetarian' => [false, true] })
        expect(described_class.describe(row)).to eq('Guest, update')
      end

      it 'falls back for an update even when the row reads like a create' do
        row = audit('Guest', 'update', { 'resident_id' => resident.id, 'vegetarian' => true })
        expect(described_class.describe(row)).to eq('Guest, update')
      end

      it 'falls back for an action it does not know' do
        row = audit('Guest', 'touch', { 'resident_id' => resident.id, 'vegetarian' => true })
        expect(described_class.describe(row)).to eq('Guest, touch')
      end

      it 'falls back when the row does not say whether the guest was vegetarian' do
        row = audit('Guest', 'create', { 'resident_id' => resident.id })
        expect(described_class.describe(row)).to eq('Guest, create')
      end
    end
  end

  # A describer loads, before it describes anything, the resident each
  # update row's bill, attendance row or guest named just before that
  # row: from the record's own history, read in order (#84). These pin
  # what it reads, and from where.
  describe 'what a describer reads first' do
    let(:other) { create(:resident, community: community, unit: unit) }

    def bill_update(cook, from:, to:)
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(from))
      bill.update!(amount: BigDecimal(to))
      [bill, bill.audits.find_by!(action: 'update')]
    end

    it 'reads only the residents when no row updates a bill or an attendance row' do
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: other, community: community)
      rows = Audited::Audit.where(auditable_type: %w[Meal Bill MealResident]).to_a
      expect(rows.map(&:action).uniq).to eq(['create'])

      expect(count_queries { described_class.for(rows) }).to eq(1)
    end

    # The records' histories, then the residents. Never the bills,
    # attendance rows or guests themselves: a record as it is now cannot
    # say who it named at an older row.
    it 'reads the history of every bill, attendance row and guest in one query, and not the records' do
      bill_update(resident, from: '30', to: '50')
      attendance = create(:meal_resident, meal: meal, resident: other, community: community, late: false)
      attendance.update!(late: true)
      guest = create(:guest, meal: meal, resident: resident)
      guest.update!(multiplier: Multiplier::HALF)
      rows = Audited::Audit.where(action: 'update').to_a
      statements = []
      recorder = ->(*, event) { statements << event[:sql] unless event[:name] == 'SCHEMA' || event[:cached] }

      ActiveSupport::Notifications.subscribed(recorder, 'sql.active_record') { described_class.for(rows) }

      expect(statements.size).to eq(2)
      expect(statements.first).to include('FROM "audits"')
      expect(statements.second).to include('FROM "residents"')
    end

    # Ids are counted per table, so a gone bill can share its id with an
    # attendance row. Only the bill's own create audit names its cook.
    it "reads a gone row's resident from a create audit of its own type" do
      bill, audit = bill_update(resident, from: '30', to: '50')
      bill.destroy!
      Audited::Audit.create!(auditable_type: 'MealResident', auditable_id: bill.id, action: 'create',
                             audited_changes: { 'resident_id' => other.id })

      expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $50.00")
    end

    # Read in one query, the histories of a bill and an attendance row
    # with the same id mix. Each record keeps its own resident: the
    # attendance row's new person must not become the bill's cook.
    it "keeps a bill's history apart from the history of an attendance row with the same id" do
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
      bill.update!(no_cost: true, amount: 0)
      attendance = create(:meal_resident, id: bill.id, meal: meal, resident: other, community: community)
      attendance.update!(resident: create(:resident, community: community, unit: unit))
      bill.update!(no_cost: false, amount: BigDecimal('50'))
      rows = Audited::Audit.where(action: 'update').order(:id).to_a
      describer = described_class.for(rows)

      expect(describer.describe(rows.last))
        .to eq("Bill for #{name} changed from $0.00 to $50.00 and no longer marked as no cost")
    end

    # A row deleted outside the app has no destroy audit, so its last audit
    # is an update, which does not name the resident.
    it "reads a gone row's resident from its create audit, not a later one" do
      bill, audit = bill_update(resident, from: '30', to: '50')
      Bill.where(id: bill.id).delete_all

      expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $50.00")
    end

    # The app has audited these records from the start, so only a row
    # written outside the app has no create row. Then the history cannot
    # say who the record named, even while the record is still there.
    it 'names an unknown cook when the history has no create row for a bill that is still there' do
      _bill, audit = bill_update(resident, from: '30', to: '50')
      Audited::Audit.where(auditable_type: 'Bill', action: 'create').delete_all

      expect(described_class.describe(audit)).to eq('Bill for unknown changed from $30.00 to $50.00')
    end
  end
end
