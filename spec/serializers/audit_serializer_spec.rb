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

  # A row with a username and no user: audited's `user` then returns that
  # text, not a record, and asking the text for a name raised, so the
  # whole meal history answered 500. The text is shown as it is:
  # shortening it as a person's name would leave only its first word.
  it 'shows the username of a row that no person made, as it is' do
    meal = create(:meal, community: community)
    audit = Audited::Audit.create!(auditable: meal, action: 'update', audited_changes: { 'description' => %w[a b] },
                                   username: 'Nightly import')

    expect(described_class.new(audit).to_h)
      .to include(user_name: 'Nightly import', description: 'Menu description updated')
  end

  # A data fix writes its rows with no user and no username, so the
  # release before this one can still show them after a rollback (it asks
  # `user` for a name). Its comment starts with who made the change.
  it 'names a data fix as the maker of its rows, from the comment' do
    meal = create(:meal, community: community)
    audit = Audited::Audit.create!(auditable: meal, action: 'update', audited_changes: { 'description' => %w[a b] },
                                   comment: 'Automatic fix (migration 20261010130000). Turned No cost off.')

    expect(described_class.new(audit).to_h).to include(user_name: 'Automatic fix')
  end

  # An empty username names nobody, so the comment says who made the row,
  # as it does for a row with no username.
  it 'names a data fix from the comment when the username is empty' do
    meal = create(:meal, community: community)
    audit = Audited::Audit.create!(auditable: meal, action: 'update', audited_changes: { 'description' => %w[a b] },
                                   username: '', comment: 'Automatic fix (migration 20261010130000).')

    expect(described_class.new(audit).to_h).to include(user_name: 'Automatic fix')
  end

  it 'leaves the name empty for a change nobody was signed in for' do
    meal = create(:meal, community: community)

    expect(described_class.new(meal.audits.first).to_h).to include(user_name: '', description: 'Meal record created')
  end
end
