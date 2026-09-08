# frozen_string_literal: true

require 'rails_helper'

# The audit sentences the meal history modal shows. Moved from
# ApplicationHelper's parse_audit (#51).
RSpec.describe AuditDescription do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

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

  it 'resolves resident name from audit trail when bill resident association is nil' do
    bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('30'))
    bill.update!(amount: BigDecimal('50'))
    audit = bill.audits.where(action: 'update').last
    stub_bill = Bill.find(bill.id)
    allow(Bill).to receive(:find_by).with(id: audit.auditable_id).and_return(stub_bill)
    allow(stub_bill).to receive(:resident).and_return(nil)
    name = ResidentNameShortener.short(resident.name)
    expect(described_class.describe(audit)).to eq("Bill for #{name} changed from $30.00 to $50.00")
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
    result = described_class.describe(audit)
    expect(result).to include('added')
  end

  it 'parses meal_resident marked late audit' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
    mr.update!(late: true)
    audit = mr.audits.where(action: 'update').last
    result = described_class.describe(audit)
    expect(result).to include('marked late')
  end

  it 'parses meal_resident vegetarian toggle audits' do
    mr = create(:meal_resident, meal: meal, resident: resident, community: community, vegetarian: false)
    mr.update!(vegetarian: true)
    audit = mr.audits.where(action: 'update').last
    result = described_class.describe(audit)
    expect(result).to include('marked veg')
    expect(result).not_to include('not veg')

    mr.update!(vegetarian: false)
    audit = mr.audits.where(action: 'update').last
    result = described_class.describe(audit)
    expect(result).to include('marked not veg')
  end

  it 'parses guest create audit' do
    guest = create(:guest, meal: meal, resident: resident, vegetarian: false)
    audit = guest.audits.first
    result = described_class.describe(audit)
    expect(result).to include('Omnivore guest')
    expect(result).to include('added')
  end

  it 'parses vegetarian guest create audit' do
    guest = create(:guest, meal: meal, resident: resident, vegetarian: true)
    audit = guest.audits.first
    result = described_class.describe(audit)
    expect(result).to include('Veg guest')
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
      audit = instance_double(Audited::Audit, auditable_type: 'Bill', action: 'update', auditable_id: bill.id,
                                              audited_changes: { 'updated_at' => [1, 2] })
      expect(described_class.describe(audit)).to eq('unknown bill changed')
    end

    it 'falls back for a meal_resident late change with no clear direction' do
      open_meal = create(:meal, community: community, date: meal.date + 1)
      meal_resident = create(:meal_resident, meal: open_meal, resident: resident, community: community)
      audit = instance_double(Audited::Audit, auditable_type: 'MealResident', action: 'update',
                                              auditable_id: meal_resident.id,
                                              audited_changes: { 'late' => [nil, nil] })
      expect(described_class.describe(audit)).to eq('MealResident, update')
    end

    it 'falls back for a record type it has never heard of' do
      audit = instance_double(Audited::Audit, auditable_type: 'Rotation', action: 'update', audited_changes: {})
      expect(described_class.describe(audit)).to eq('Rotation, update')
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

    def audit(type, action, changes, id: nil)
      instance_double(Audited::Audit, auditable_type: type, action: action, audited_changes: changes,
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

      it 'falls back for an update that touched neither late nor vegetarian' do
        row = audit('MealResident', 'update', { 'multiplier' => [2, 1] }, id: attendance.id)
        expect(described_class.describe(row)).to eq('MealResident, update')
      end

      it 'falls back for an action it does not know' do
        row = audit('MealResident', 'touch', { 'resident_id' => resident.id }, id: attendance.id)
        expect(described_class.describe(row)).to eq('MealResident, touch')
      end
    end

    describe 'guest rows' do
      it 'falls back for an update, which the API never writes' do
        row = audit('Guest', 'update', { 'resident_id' => resident.id, 'vegetarian' => [false, true] })
        expect(described_class.describe(row)).to eq('Guest, update')
      end

      it 'falls back when the row does not say whether the guest was vegetarian' do
        row = audit('Guest', 'create', { 'resident_id' => resident.id })
        expect(described_class.describe(row)).to eq('Guest, create')
      end
    end
  end
end
