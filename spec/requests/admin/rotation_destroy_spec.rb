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

  it 'renders the new form with the unassigned meals as check boxes' do
    meal = create(:meal, community: community, rotation: nil, date: Date.current + 30)

    get '/rotations/new'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(meal.date.to_s)
  end
end
