# frozen_string_literal: true

require 'rails_helper'

# The history row a settlement writes for each meal it claims, in place
# of the row the audited gem would write for a save of reconciliation_id
# (spec/services/settlement_history_spec.rb has the settlement's side).
# The row must name what a save in the same place names: the person, the
# request's id and its address.
RSpec.describe SettledMealHistory do
  let(:community) { create(:community) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:meal) { create(:meal, community: community) }
  let(:who) { %w[user_type user_id username request_uuid remote_address] }

  def settled_row(meal_id)
    Audited::Audit.where(auditable_type: 'Meal', auditable_id: meal_id, action: 'update')
                  .where("audited_changes ? 'reconciliation_id'").sole
  end

  # What the audited gem keeps for an admin request: the admin the
  # controller names, and the request's id and address. Audited::Sweeper
  # does this around every request.
  def in_an_admin_request(user, &)
    request = Struct.new(:remote_ip, :uuid).new('203.0.113.7', 'request-1')
    controller = Struct.new(:request, :audited_user).new(request, user)
    Audited::Sweeper.new.around(controller, &)
  end

  it 'names the person, the request and the address that a save in the same request names' do
    other = create(:meal, community: community)

    in_an_admin_request(admin) do
      described_class.record(meal_ids: [meal.id], reconciliation_id: 7)
      other.update!(description: 'Soup')
    end

    saved = other.audits.last.attributes.slice(*who)
    expect(saved).to eq('user_type' => 'AdminUser', 'user_id' => admin.id, 'username' => nil,
                        'request_uuid' => 'request-1', 'remote_address' => '203.0.113.7')
    expect(settled_row(meal.id).attributes.slice(*who)).to eq(saved)
  end

  it 'names nobody outside a request, and gives the row a request id of its own' do
    described_class.record(meal_ids: [meal.id], reconciliation_id: 7)

    row = settled_row(meal.id)
    expect(row.attributes.slice('user_type', 'user_id', 'username', 'remote_address')).to all(satisfy { |_, v| v.nil? })
    expect(row.request_uuid).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  it "takes each meal's next version, and version 1 for a meal with no history" do
    meal.update!(description: 'Soup')
    bare_id = Meal.insert!({ community_id: community.id, rotation_id: meal.rotation_id, date: meal.date + 1 },
                           returning: :id).first.fetch('id')

    described_class.record(meal_ids: [meal.id, bare_id], reconciliation_id: 7)

    expect(meal.audits.pluck(:version)).to eq([1, 2, 3])
    expect(settled_row(meal.id).version).to eq(3)
    expect(settled_row(bare_id).version).to eq(1)
  end

  # A settlement that only carries corrections claims no meal.
  it 'reads and writes nothing for no meals' do
    expect(count_queries { described_class.record(meal_ids: [], reconciliation_id: 7) }).to eq(0)
  end
end
