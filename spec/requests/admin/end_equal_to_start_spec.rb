# frozen_string_literal: true

require 'rails_helper'

# An event or a common house booking that ends when it starts holds no
# time, so the model refuses it when a save sets or changes its times,
# except midnight to midnight, which is how a notice is saved (#141). The
# API side is checked in spec/requests/api/v1; this file checks the four
# admin forms, which save through the same model.
#
# The community is in New York and the app's zone is Los Angeles, so a
# 00:00 that the admin form read in the wrong zone would be refused. The
# days are an ordinary one and both daylight saving days.
RSpec.describe 'Admin forms and an end equal to its start' do
  let(:community) { create(:community, timezone: 'America/New_York') }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:new_york) { ActiveSupport::TimeZone['America/New_York'] }
  let(:days) { [[2026, 4, 15], [2026, 3, 8], [2026, 11, 1]] }
  let(:refused) { 'Start time must occur before end time' }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # The five menus of the start and of the end (year, month, day, hour,
  # minute), the way the form names them, both on the same day.
  def times(day, start, finish)
    { 'start_date' => day + start, 'end_date' => day + finish }.flat_map do |field, parts|
      parts.each_with_index.map { |value, index| ["#{field}(#{index + 1}i)", value.to_s] }
    end.to_h
  end

  # ActiveAdmin shows the form again as a 200, with the model's message
  # on the page.
  def expect_refused
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(refused)
  end

  describe 'event' do
    it 'refuses a new event that ends when it starts, and takes one from midnight to midnight' do
      days.each do |day|
        post '/events', params: { event: times(day, [14, 0], [14, 0]).merge('title' => 'Same time', 'allday' => '0') }
        expect_refused

        post '/events', params: { event: times(day, [0, 0], [0, 0]).merge('title' => 'Notice', 'allday' => '0') }
        expect(response).to redirect_to("/events/#{Event.last.id}")
      end

      expect(Event.order(:id).pluck(:start_date, :end_date)).to eq(days.map { |day| [new_york.local(*day)] * 2 })
    end

    it 'refuses an edit that makes an event end when it starts, but takes midnight to midnight' do
      event = create(:event, community: community, allday: false, start_date: new_york.local(2026, 4, 10, 18),
                             end_date: new_york.local(2026, 4, 10, 21))

      days.each do |day|
        before = event.reload.attributes
        patch "/events/#{event.id}", params: { event: times(day, [14, 0], [14, 0]) }
        expect_refused
        expect(event.reload.attributes).to eq(before)

        patch "/events/#{event.id}", params: { event: times(day, [0, 0], [0, 0]) }
        expect(response).to redirect_to("/events/#{event.id}")
        expect(event.reload).to have_attributes(start_date: new_york.local(*day), end_date: new_york.local(*day))
      end
    end
  end

  describe 'common house' do
    it 'refuses a new booking that ends when it starts, and takes one from midnight to midnight' do
      days.each do |day|
        post '/common_house_reservations',
             params: { common_house_reservation: times(day, [14, 0], [14, 0]).merge('resident_id' => resident.id) }
        expect_refused

        post '/common_house_reservations',
             params: { common_house_reservation: times(day, [0, 0], [0, 0]).merge('resident_id' => resident.id) }
        expect(response).to redirect_to("/common_house_reservations/#{CommonHouseReservation.last.id}")
      end

      expect(CommonHouseReservation.order(:id).pluck(:start_date, :end_date))
        .to eq(days.map { |day| [new_york.local(*day)] * 2 })
    end

    it 'refuses an edit that makes a booking end when it starts, but takes midnight to midnight' do
      booking = create(:common_house_reservation, community: community, resident: resident,
                                                  start_date: new_york.local(2026, 4, 10, 18),
                                                  end_date: new_york.local(2026, 4, 10, 21))

      days.each do |day|
        before = booking.reload.attributes
        patch "/common_house_reservations/#{booking.id}",
              params: { common_house_reservation: times(day, [14, 0], [14, 0]) }
        expect_refused
        expect(booking.reload.attributes).to eq(before)

        patch "/common_house_reservations/#{booking.id}",
              params: { common_house_reservation: times(day, [0, 0], [0, 0]) }
        expect(response).to redirect_to("/common_house_reservations/#{booking.id}")
        expect(booking.reload).to have_attributes(start_date: new_york.local(*day), end_date: new_york.local(*day))
      end
    end
  end

  # Production has four rows from before #141 that end when they start,
  # not at midnight: events 143, 489 and 1056, and booking 1117. The edit
  # form sends the stored times back with every save, so a new title must
  # still save. A move to other times that end when they start is refused,
  # and a later end saves.
  describe 'a row from before #141 that ends when it starts, not at midnight' do
    let(:old_day) { [2022, 7, 26] }
    let(:moment) { new_york.local(*old_day, 8, 0) }

    it 'saves an event with a new title, refuses a move to other equal times, and saves a later end' do
      event = create(:event, community: community, allday: false, start_date: moment, end_date: moment + 1.hour)
      event.update_columns(end_date: moment)

      patch "/events/#{event.id}", params: { event: times(old_day, [8, 0], [8, 0]).merge('title' => 'Renamed') }
      expect(response).to redirect_to("/events/#{event.id}")
      expect(event.reload).to have_attributes(title: 'Renamed', start_date: moment, end_date: moment)

      patch "/events/#{event.id}", params: { event: times(old_day, [14, 0], [14, 0]) }
      expect_refused
      expect(event.reload).to have_attributes(start_date: moment, end_date: moment)

      patch "/events/#{event.id}", params: { event: times(old_day, [8, 0], [9, 0]) }
      expect(response).to redirect_to("/events/#{event.id}")
      expect(event.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)
    end

    it 'saves a booking with a new title, refuses a move to other equal times, and saves a later end' do
      booking = create(:common_house_reservation, community: community, resident: resident,
                                                  start_date: moment, end_date: moment + 1.hour)
      booking.update_columns(end_date: moment)
      path = "/common_house_reservations/#{booking.id}"

      patch path, params: { common_house_reservation: times(old_day, [8, 0], [8, 0]).merge('title' => 'Renamed') }
      expect(response).to redirect_to(path)
      expect(booking.reload).to have_attributes(title: 'Renamed', start_date: moment, end_date: moment)

      patch path, params: { common_house_reservation: times(old_day, [14, 0], [14, 0]) }
      expect_refused
      expect(booking.reload).to have_attributes(start_date: moment, end_date: moment)

      patch path, params: { common_house_reservation: times(old_day, [8, 0], [9, 0]) }
      expect(response).to redirect_to(path)
      expect(booking.reload).to have_attributes(start_date: moment, end_date: moment + 1.hour)
    end
  end
end
