# frozen_string_literal: true

require 'rails_helper'

# A delete renumbers the rotations that are left and puts their colors
# back on the cycle. Both are writes, and at SERIALIZABLE the database
# can refuse any statement (ADR 0005). Until 2026-10-10 both ran after
# the delete had committed, so a refusal there reached the conflict
# rescue: the rotation was gone, the page said "Nothing was saved", and
# the numbers and colors stayed wrong until the next rotation change.
# Now they run inside the delete's transaction, and a refusal takes the
# delete back with it. No test transaction, so the delete really
# commits or rolls back.
RSpec.describe 'Admin rotation destroy when the database refuses the renumber or the recolor' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:nothing_saved) { 'Someone else was changing this at the same time. Nothing was saved. Try again.' }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  # Two upcoming rotations. Only the last one may be deleted.
  def last_of_two_rotations
    first = create(:rotation, community: community)
    create(:meal, community: community, rotation: first, date: community.today + 30)
    create(:rotation, community: community).tap do |last|
      create(:meal, community: community, rotation: last, date: community.today + 40)
    end
  end

  it 'keeps the rotation when the recolor is refused, so "Nothing was saved" is true' do
    rotation = last_of_two_rotations
    allow(Rotation).to receive(:recolor_community)
      .and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')

    delete "/rotations/#{rotation.id}"

    expect(Rotation.exists?(rotation.id)).to be(true)
    expect(Meal.where(rotation_id: rotation.id).count).to eq(1)
    expect(flash[:alert]).to eq(nothing_saved)
  end

  it 'keeps the rotation when the renumber is refused, so "Nothing was saved" is true' do
    rotation = last_of_two_rotations
    # rubocop:disable-next RSpec/AnyInstance
    allow_any_instance_of(Rotation).to receive(:set_place_value)
      .and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')

    delete "/rotations/#{rotation.id}"

    expect(Rotation.exists?(rotation.id)).to be(true)
    expect(flash[:alert]).to eq(nothing_saved)
  end
end
