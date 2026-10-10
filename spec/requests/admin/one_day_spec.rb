# frozen_string_literal: true

require 'rails_helper'

# An event or a common house booking must start and end on the same day,
# in the community's zone (#154). The app's forms give one day and two
# times, so only the admin forms, which take a full date and time for
# each end, could make one that ends on a later day. They save through
# the model, which refuses it; this file checks that each admin form
# shows the refusal and keeps the row as it was. The model side is in
# spec/models.
#
# The community is in New York and the app's zone is Los Angeles, so a
# day read in the wrong zone, or in UTC, gives the wrong answer. 00:30 to
# 23:30 in New York is two days in UTC and in Los Angeles. The days are
# an ordinary one and both daylight saving days.
RSpec.describe 'Admin forms and an entry that ends on a later day' do
  let(:community) { create(:community, timezone: 'America/New_York') }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:new_york) { ActiveSupport::TimeZone['America/New_York'] }
  let(:days) { [Date.new(2026, 4, 15), Date.new(2026, 3, 8), Date.new(2026, 11, 1)] }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # The five menus of the start and of the end (year, month, day, hour,
  # minute), the way the form names them.
  def times(start_day, start, end_day, finish)
    { 'start_date' => [start_day, start], 'end_date' => [end_day, finish] }.flat_map do |field, (day, time)|
      [day.year, day.month, day.day, *time].each_with_index.map do |value, index|
        ["#{field}(#{index + 1}i)", value.to_s]
      end
    end.to_h
  end

  def late_night(day)
    times(day, [22, 0], day + 1, [1, 0])
  end

  def whole_day(day)
    times(day, [0, 30], day, [23, 30])
  end

  def at(day, hour, minute)
    new_york.local(day.year, day.month, day.day, hour, minute)
  end

  # ActiveAdmin shows the form again as a 200, with the model's message
  # on the page.
  def expect_refused(message)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(message)
  end

  describe 'event' do
    let(:refused) { 'An event must start and end on the same day.' }

    it 'refuses a new event that runs past midnight, and takes one from 00:30 to 23:30' do
      days.each do |day|
        post '/events', params: { event: late_night(day).merge('title' => 'Late', 'allday' => '0') }
        expect_refused(refused)

        post '/events', params: { event: whole_day(day).merge('title' => 'Long', 'allday' => '0') }
        expect(response).to redirect_to("/events/#{Event.last.id}")
      end

      expect(Event.order(:id).pluck(:title, :start_date, :end_date))
        .to eq(days.map { |day| ['Long', at(day, 0, 30), at(day, 23, 30)] })
    end

    it 'refuses an edit that makes an event end on a later day, and keeps the event as it was' do
      event = create(:event, community: community, allday: false, start_date: at(days[0] - 5, 18, 0),
                             end_date: at(days[0] - 5, 21, 0))

      days.each do |day|
        before = event.reload.attributes
        patch "/events/#{event.id}", params: { event: late_night(day) }
        expect_refused(refused)
        expect(event.reload.attributes).to eq(before)
      end
    end

    it 'takes an all-day event, whatever end the form sends' do
      post '/events', params: { event: late_night(days[0]).merge('title' => 'Fair', 'allday' => '1') }

      expect(response).to redirect_to("/events/#{Event.last.id}")
    end
  end

  describe 'common house' do
    let(:refused) { 'A booking must start and end on the same day.' }

    it 'refuses a new booking that runs past midnight, and takes one from 00:30 to 23:30' do
      days.each do |day|
        post '/common_house_reservations',
             params: { common_house_reservation: late_night(day).merge('resident_id' => resident.id) }
        expect_refused(refused)

        post '/common_house_reservations',
             params: { common_house_reservation: whole_day(day).merge('resident_id' => resident.id) }
        expect(response).to redirect_to("/common_house_reservations/#{CommonHouseReservation.last.id}")
      end

      expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date))
        .to eq(days.map { |day| [at(day, 0, 30), at(day, 23, 30)] })
    end

    it 'refuses an edit that makes a booking end on a later day, and keeps the booking as it was' do
      booking = create(:common_house_reservation, community: community, resident: resident,
                                                  start_date: at(days[0] - 5, 18, 0), end_date: at(days[0] - 5, 21, 0))

      days.each do |day|
        before = booking.reload.attributes
        patch "/common_house_reservations/#{booking.id}", params: { common_house_reservation: late_night(day) }
        expect_refused(refused)
        expect(booking.reload.attributes).to eq(before)
      end
    end
  end
end
