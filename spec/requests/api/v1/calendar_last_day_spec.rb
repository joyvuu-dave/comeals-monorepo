# frozen_string_literal: true

require 'rails_helper'

# A month's grid is six weeks. Its last day belongs to the next month,
# but it is still on screen, so what happens on it must be sent. The
# window's end is a date string; compared with a datetime column it
# means midnight, and an event at 10:00 that day fell outside (#79).
RSpec.describe 'the calendar on the last day of the grid' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  # April 2026's grid runs March 29 .. May 9.
  let(:first_day) { Time.zone.local(2026, 3, 29, 10) }
  let(:last_day) { Time.zone.local(2026, 5, 9, 10) }

  def calendar_body
    get "/api/v1/communities/#{community.id}/calendar/2026-04-15", params: { token: token }
    expect(response).to have_http_status(:ok)
    response.body
  end

  it 'sends an event that starts during the last day' do
    create(:event, community: community, title: 'LastDayEvent',
                   start_date: last_day, end_date: last_day + 1.hour)
    create(:event, community: community, title: 'FirstDayEvent',
                   start_date: first_day, end_date: first_day + 1.hour)
    create(:event, community: community, title: 'NextDayEvent',
                   start_date: last_day + 1.day, end_date: last_day + 25.hours)

    body = calendar_body
    expect(body).to include('LastDayEvent')
    expect(body).to include('FirstDayEvent')
    expect(body).not_to include('NextDayEvent')
  end

  it 'sends a common house reservation that starts during the last day' do
    reservation = create(:common_house_reservation, community: community, resident: resident,
                                                    start_date: last_day, end_date: last_day + 1.hour)

    expect(JSON.parse(calendar_body)['common_house_reservations'].pluck('id'))
      .to eq([reservation.cache_key_with_version])
  end

  # The admin form takes any start and end, so a booking can last days.
  # One that starts the day before the grid still holds April 2, so the
  # grid must show it there; it used to be left out, and a person saw a
  # free day that the server then refused.
  it 'sends a common house reservation that starts before the first day and ends inside the grid' do
    reservation = create(:common_house_reservation, community: community, resident: resident,
                                                    start_date: Time.zone.local(2026, 3, 28, 18),
                                                    end_date: Time.zone.local(2026, 4, 3, 10))

    expect(JSON.parse(calendar_body)['common_house_reservations'].pluck('id'))
      .to eq([reservation.cache_key_with_version])

    post '/api/v1/common-house-reservations',
         params: { token: token, resident_id: resident.id, start_year: 2026, start_month: 4, start_day: 2,
                   start_hours: 12, start_minutes: 0, end_hours: 13, end_minutes: 0 }
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['message']).to eq('Time period is already taken')
  end
end
