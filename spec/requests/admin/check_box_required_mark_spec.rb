# frozen_string_literal: true

require 'rails_helper'

# ActiveAdmin's forms mark a field the model requires with a red "*"
# (Formtastic reads the model's presence and inclusion checks). Since
# de60eb10 every true/false column has an inclusion check, so every check
# box got the "*" too. A check box always sends a value (a hidden field
# sends 0 when it is not checked), so it cannot be left empty, and the
# "*" only made people wonder what they had to fill in. Check boxes have
# no "*" (config/initializers/check_box_not_required.rb); a text field the
# model requires keeps it.
RSpec.describe 'Admin check boxes and the required mark' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def required_mark(input_id)
    expect(response).to have_http_status(:ok)
    input = response.parsed_body.at_css("##{input_id}")
    expect(input).not_to be_nil, "no #{input_id} on the page"
    input.at_css('label abbr[title="required"]')
  end

  it 'shows no "*" on any of the resident form\'s check boxes' do
    resident = create(:resident, community: community)

    get "/residents/#{resident.id}/edit"

    %w[vegetarian can_cook can_reconcile active].each do |column|
      expect(required_mark("resident_#{column}_input")).to be_nil, "#{column} has the *"
    end
  end

  it 'shows no "*" on the meal form\'s Closed box' do
    meal = create(:meal, community: community)

    get "/meals/#{meal.id}/edit"

    expect(required_mark('meal_closed_input')).to be_nil
  end

  it 'shows no "*" on the event form\'s All day box' do
    event = create(:event, community: community)

    get "/events/#{event.id}/edit"

    expect(required_mark('event_allday_input')).to be_nil
  end

  it 'shows no "*" on the admin form\'s Superuser box' do
    other = create(:admin_user, community: community)

    get "/admin_users/#{other.id}/edit"

    expect(required_mark('admin_user_superuser_input')).to be_nil
  end

  # The mark still says what it says for a field that can be left empty.
  it 'keeps the "*" on a text field the model requires' do
    resident = create(:resident, community: community)

    get "/residents/#{resident.id}/edit"

    expect(required_mark('resident_name_input')).not_to be_nil
  end

  # A new record is checked too: Formtastic reads the checks the same
  # way for a new record and for a saved one.
  it 'shows no "*" on the check boxes of a new resident' do
    get '/residents/new'

    expect(required_mark('resident_active_input')).to be_nil
  end
end
