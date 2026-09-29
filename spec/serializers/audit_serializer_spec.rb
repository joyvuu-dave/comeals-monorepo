# frozen_string_literal: true

require 'rails_helper'

# The rows of the meal history modal, value by value.
RSpec.describe AuditSerializer do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Ann Lee', multiplier: 2) }

  it 'names the change, who made it, and when' do
    meal = Audited.audit_class.as_user(resident) { create(:meal, community: community) }
    audit = meal.audits.first

    expect(described_class.new(audit).to_h).to eq(
      id: audit.id, user_name: 'Ann', description: 'Meal record created', display_time: audit.created_at
    )
  end

  it 'names the cook of a single bill row' do
    meal = create(:meal, community: community)
    bill = create(:bill, meal: meal, resident: resident, community: community)

    expect(described_class.new(bill.audits.first).to_h).to include(description: 'Ann added as cook')
  end

  # The meal history modal serializes the whole list at once. One
  # describer is built from every row, so each table is read once for
  # the list (#84), and every row still names its resident. prosopite
  # fails this example if the lookups run once a row instead.
  it 'describes every row of a list, with the lookups done once for the list' do
    meal = create(:meal, community: community)
    other = create(:resident, community: community, unit: unit, name: 'Bo Park')
    attendance = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)
    attendance.update!(late: true)
    bill = create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('30'))
    bill.update!(amount: BigDecimal('50'))

    rows = described_class.new(meal.total_audits).to_h

    # Newest first, the order Meal#total_audits gives.
    expect(rows.pluck(:description)).to eq(['Bill for Bo changed from $30.00 to $50.00', 'Bo added as cook',
                                            'Ann marked late', 'Ann added', 'Meal record created'])
  end

  it 'leaves the name empty for a change nobody was signed in for' do
    meal = create(:meal, community: community)

    expect(described_class.new(meal.audits.first).to_h).to include(user_name: '', description: 'Meal record created')
  end
end
