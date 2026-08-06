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
end
