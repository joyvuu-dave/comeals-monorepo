# frozen_string_literal: true

require 'rails_helper'

# A change of the community's time zone moves every event and common
# house booking on the clock: 20:00 in Los Angeles is 23:00 in New York.
# Some then end on the next day (#173). So the community form does not
# save a new zone at once when something on the calendar would move. It
# shows the form again with the numbers and the first events that would
# cross midnight, and saves on the second submit.
RSpec.describe 'Admin community form: a change of time zone' do
  let!(:community) { create(:community, name: 'Old name', timezone: 'America/Los_Angeles') }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def submit(attributes, confirm: nil)
    params = { community: attributes }
    params[:confirm_timezone] = confirm if confirm
    patch "/communities/#{community.id}", params: params
  end

  # On a daylight saving day, to check the day read in the zone.
  def late_event
    start = Time.zone.local(2026, 3, 8, 20)
    create(:event, community: community, title: 'Late movie', start_date: start, end_date: start + 3.hours,
                   allday: false)
  end

  it 'shows what would move and does not save, then saves on the second submit' do
    late_event
    start = Time.zone.local(2026, 4, 15, 14)
    create(:common_house_reservation, community: community, start_date: start, end_date: start + 1.hour)

    submit({ timezone: 'America/New_York', name: 'New name' })

    expect(response).to have_http_status(:ok)
    expect(community.reload).to have_attributes(timezone: 'America/Los_Angeles', name: 'Old name')
    page = response.body
    expect(page).to include('2 events and common house bookings would show at different clock times.')
    expect(page).to include('1 would end on the day after it starts.')
    expect(page).to include('Sun Mar 8, 2026: Event, Late movie')
    expect(page).to include('name="confirm_timezone" id="confirm_timezone" value="America/New_York"')
    expect(page).to include('value="New name"')

    submit({ timezone: 'America/New_York', name: 'New name' }, confirm: 'America/New_York')

    expect(response).to redirect_to("/communities/#{community.id}")
    expect(community.reload).to have_attributes(timezone: 'America/New_York', name: 'New name')
  end

  it 'asks again when the second submit names another zone' do
    late_event

    submit({ timezone: 'America/Chicago' }, confirm: 'America/New_York')

    expect(response).to have_http_status(:ok)
    expect(community.reload.timezone).to eq('America/Los_Angeles')
    expect(response.body).to include('name="confirm_timezone" id="confirm_timezone" value="America/Chicago"')
  end

  it 'saves at once when nothing on the calendar would move, or the zone stays' do
    late_event
    submit({ name: 'Same zone', timezone: 'America/Los_Angeles' })
    expect(response).to redirect_to("/communities/#{community.id}")

    Event.delete_all
    submit({ timezone: 'America/New_York' })
    expect(response).to redirect_to("/communities/#{community.id}")
    expect(community.reload.timezone).to eq('America/New_York')
  end

  it 'lists the first ten that would cross midnight, and counts them all' do
    12.times do |n|
      start = Time.zone.local(2026, 5, 1 + n, 20, 30)
      create(:event, community: community, title: "Night #{n + 1}", start_date: start, end_date: start + 2.hours,
                     allday: false)
    end

    submit({ timezone: 'America/New_York' })

    page = response.body
    expect(page).to include('12 events and common house bookings would show at different clock times.')
    expect(page).to include('12 would end on the day after they start.')
    expect(page).to include('Sun May 10, 2026: Event, Night 10')
    expect(page).not_to include('Night 11')
    expect(page).to include('The first 10 of 12.')
  end

  it 'counts the all-day events that would show on another day' do
    create(:event, community: community, title: 'Work day', allday: true, start_date: Time.zone.local(2026, 4, 15),
                   end_date: nil)

    submit({ timezone: 'Pacific/Honolulu' })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('1 all-day event would show on the day before or after.')
  end

  it 'still refuses a zone that is not on the list, without asking first' do
    late_event

    submit({ timezone: 'Mars/Olympus' })

    expect(community.reload.timezone).to eq('America/Los_Angeles')
    expect(response.body).to include('not included in the list')
    expect(response.body).not_to include('confirm_timezone')
  end
end
