# frozen_string_literal: true

require 'rails_helper'

# Deleting a rotation is how a schedule change reaches the calendar early.
# The model refuses anything unsafe; the admin page must show that reason,
# not bounce silently.
RSpec.describe 'Admin rotation destroy' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  it 'refuses a rotation whose meals already happened, and says why' do
    rotation = create(:rotation, community: community)
    create(:meal, community: community, rotation: rotation, date: Date.yesterday)

    expect { delete "/rotations/#{rotation.id}" }.not_to change(Rotation, :count)

    expect(response).to redirect_to(admin_rotations_path)
    expect(flash[:alert]).to include('already happened, are closed or reconciled')
  end

  it 'deletes the last rotation when none of its meals were touched' do
    rotation = create(:rotation, community: community)
    create(:meal, community: community, rotation: rotation, date: Date.current + 30)

    expect { delete "/rotations/#{rotation.id}" }.to change(Rotation, :count).by(-1)
    expect(response).to redirect_to(admin_rotations_path)
  end

  # The form is gone (#78): its check-box list sent only the checked meal
  # ids, Rails read that as the whole list, and `dependent: :destroy`
  # deleted every meal already in the rotation. There is no admin path
  # that writes a rotation's meals now.
  describe 'the rotation form' do
    it 'has no new or edit page' do
      rotation = create(:rotation, community: community)

      # "new" is read as a show id now, so it is a missing record; both
      # are a 404 in production.
      expect { get '/rotations/new' }.to raise_error(ActiveRecord::RecordNotFound)
      expect { get "/rotations/#{rotation.id}/edit" }.to raise_error(ActionController::RoutingError)
    end

    it 'cannot replace a rotation\'s meals, so its existing meals survive' do
      rotation = create(:rotation, community: community)
      existing = create(:meal, community: community, rotation: rotation, date: Date.current + 30)
      loose = create(:meal, community: community, rotation: nil, date: Date.current + 40)

      expect do
        patch "/rotations/#{rotation.id}", params: { rotation: { meal_ids: [loose.id] } }
      end.to raise_error(ActionController::RoutingError)

      expect(Meal.exists?(existing.id)).to be(true)
      expect(existing.reload.rotation_id).to eq(rotation.id)
      expect(loose.reload.rotation_id).to be_nil
    end
  end
end
