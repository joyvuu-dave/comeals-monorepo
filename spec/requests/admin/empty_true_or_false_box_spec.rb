# frozen_string_literal: true

require 'rails_helper'

# Issue #139, on the admin forms. A check box always sends "0" or "1", so
# only a request made by hand sends "". Rails reads "" as nil for a
# true/false column. Each of these columns is NOT NULL, so before its
# model checked it, the nil reached the database and the form answered
# 500. Now the form comes back with "must be true or false" next to the
# box, and nothing is saved. The resident form's four boxes are in
# resident_form_spec.rb; the model checks are in each model's spec.
RSpec.describe 'Admin forms and an empty true/false box' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # ActiveAdmin shows the form again as a 200, with the error under the
  # field.
  def box_error(form, column)
    expect(response).to have_http_status(:ok)
    response.parsed_body.at_css("##{form}_#{column}_input .inline-errors")&.text
  end

  it 'refuses a meal with closed "", and leaves the meal open' do
    meal = create(:meal, community: community)

    patch "/meals/#{meal.id}", params: { meal: { closed: '' } }

    expect(box_error('meal', 'closed')).to eq('must be true or false')
    expect(meal.reload.closed).to be(false)
  end

  it 'refuses an event with allday "", and leaves it all day' do
    event = create(:event, community: community, allday: true)

    patch "/events/#{event.id}", params: { event: { allday: '' } }

    expect(box_error('event', 'allday')).to eq('must be true or false')
    expect(event.reload.allday).to be(true)
  end

  # Another admin, not yourself. For your own box, the controller stops
  # the "" first ("You cannot remove your own superuser access"), so the
  # model never sees it.
  it 'refuses another admin with superuser "", and leaves them a superuser' do
    other = create(:admin_user, community: community, superuser: true)

    patch "/admin_users/#{other.id}", params: { admin_user: { superuser: '' } }

    expect(box_error('admin_user', 'superuser')).to eq('must be true or false')
    expect(other.reload.superuser).to be(true)
  end
end
