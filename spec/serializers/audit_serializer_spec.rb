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

  it 'leaves the name empty for a change nobody was signed in for' do
    meal = create(:meal, community: community)

    expect(described_class.new(meal.audits.first).to_h).to include(user_name: '', description: 'Meal record created')
  end
end
