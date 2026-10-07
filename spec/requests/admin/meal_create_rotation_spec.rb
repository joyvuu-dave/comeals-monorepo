# frozen_string_literal: true

require 'rails_helper'

# Every meal belongs to a rotation (#100). The admin New Meal form makes
# one-off meals, so it asks which rotation the new meal goes in. Before
# this, the form saved a meal with no rotation, and then the nightly
# EnsureRotationsJob raised every night until someone fixed the data.
RSpec.describe 'Admin meal create and its rotation' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:rotation) { create(:rotation, community: community) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
    create(:meal, community: community, rotation: rotation, date: community.today + 3)
  end

  def create_meal(date:, rotation_id:)
    post '/meals', params: { meal: { date: date.iso8601, closed: '0', rotation_id: rotation_id } }
  end

  it 'saves the meal in the rotation the admin picked' do
    expect { create_meal(date: community.today + 10, rotation_id: rotation.id) }.to change(Meal, :count).by(1)

    meal = Meal.find_by!(date: community.today + 10)
    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.rotation).to eq(rotation)
  end

  it 'refuses a meal with no rotation, and says why on the form' do
    expect { create_meal(date: community.today + 10, rotation_id: '') }.not_to change(Meal, :count)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Rotation must be chosen. Every meal belongs to a rotation.')
  end

  # The script in active_admin.js picks a rotation when the date
  # changes; on a new form the menu starts blank.
  it 'offers every rotation on the New Meal form, by number and dates, with none chosen' do
    later = create(:rotation, community: community)
    create(:meal, community: community, rotation: later, date: community.today + 20)

    get '/meals/new'

    menu = response.parsed_body.at_css('select#meal_rotation_id')
    options = menu.css('option').map { |option| [option.text, option['value'], option['data-first-date']] }
    expect(options).to eq(
      [['Choose a rotation', '', nil],
       ["Rotation 2: #{DateRangeDescription.for(community.today + 20, community.today + 20)}", later.id.to_s,
        (community.today + 20).iso8601],
       ["Rotation 1: #{DateRangeDescription.for(community.today + 3, community.today + 3)}", rotation.id.to_s,
        (community.today + 3).iso8601]]
    )
    expect(menu.at_css('option[selected]')).to be_nil
  end

  # A meal keeps the rotation it was made in. The edit form has no menu,
  # and a hand-made request cannot move a meal to another rotation.
  it 'has no rotation menu on the edit form, and ignores a rotation sent to it' do
    meal = Meal.find_by!(date: community.today + 3)
    other = create(:rotation, community: community)

    get "/meals/#{meal.id}/edit"
    expect(response.parsed_body.at_css('#meal_rotation_id')).to be_nil

    patch "/meals/#{meal.id}", params: { meal: { rotation_id: other.id } }
    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload.rotation).to eq(rotation)
  end

  it 'leaves the nightly job able to extend the calendar' do
    create_meal(date: community.today + 10, rotation_id: rotation.id)

    expect { EnsureRotationsJob.perform_now }.to change(Rotation, :count)
    expect(community.meals.where(date: (community.today + EnsureRotationsJob::HORIZON)..)).to exist
  end
end
