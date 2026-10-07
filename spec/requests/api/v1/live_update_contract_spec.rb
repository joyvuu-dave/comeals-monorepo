# frozen_string_literal: true

require 'rails_helper'

# The live-update contract: every write that changes what a screen shows
# must reach that screen through Pusher, whatever path wrote it. The SPA
# never polls. A write that is not pushed leaves a screen wrong until
# something else happens to refetch it (a navigation, a reconnect, the
# next write), and on a shared screen that can be hours.
#
# Channels:
#   community-<id>-calendar-<year>-<month>   a calendar month
#   meal-<id>                                one meal's page
#   community-<id>-residents                 anything that lists residents
#
# These examples write through the models, not the API, because the API
# is not the only writer: ActiveAdmin, the nightly rotation job, and the
# settlement all write the same rows.
RSpec.describe 'live updates: every write reaches the screen that shows it' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:other_resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 4, 10)) }

  def calendar_channel(date)
    community.calendar_cache_key(date.year, date.month)
  end

  def residents_channel
    "community-#{community.id}-residents"
  end

  def meal_channel(meal_or_id)
    id = meal_or_id.respond_to?(:id) ? meal_or_id.id : meal_or_id
    "meal-#{id}"
  end

  def expect_pushed(channel)
    expect(Pusher).to have_received(:trigger).with(channel, 'update', anything, any_args).at_least(:once)
  end

  def expect_not_pushed(channel)
    expect(Pusher).not_to have_received(:trigger).with(channel, 'update', anything, any_args)
  end

  describe 'writes that only the admin makes' do
    it 'a bill written through the model pushes the meal page and the calendar month' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('12'))

      expect_pushed(meal_channel(meal))
      expect_pushed(calendar_channel(meal.date))
    end

    it 'an attendance row written through the model pushes the meal page and the calendar month' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect_pushed(meal_channel(meal))
      expect_pushed(calendar_channel(meal.date))
    end

    it 'a guest written through the model pushes the meal page and the calendar month' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      create(:guest, meal: meal, resident: resident)

      expect_pushed(meal_channel(meal))
      expect_pushed(calendar_channel(meal.date))
    end

    it 'a meal edited through the model pushes the meal page' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      meal.update!(closed: true)

      expect_pushed(meal_channel(meal))
      expect_pushed(calendar_channel(meal.date))
    end

    it 'a meal moved to another month pushes both months' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      meal.update!(date: Date.new(2026, 6, 10))

      expect_pushed(calendar_channel(Date.new(2026, 4, 1)))
      expect_pushed(calendar_channel(Date.new(2026, 6, 1)))
    end

    it 'a deleted meal pushes its calendar month' do
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      meal.destroy!

      expect_pushed(calendar_channel(Date.new(2026, 4, 1)))
    end

    it 'a recolored rotation pushes the months of its meals' do
      rotation = create(:rotation, community: community)
      meal.update!(rotation: rotation)
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      rotation.update!(color: 'red')

      expect_pushed(calendar_channel(meal.date))
    end

    it 'a resident change the meal page shows pushes the residents channel' do
      resident
      %i[vegetarian can_cook].each do |column|
        RSpec::Mocks.space.proxy_for(Pusher).reset
        allow(Pusher).to receive(:trigger)

        resident.update!(column => !resident.public_send(column))

        expect_pushed(residents_channel)
      end
    end

    it 'a community time zone change pushes the residents channel, because every open tab keeps the zone' do
      # The SPA writes the zone to a cookie at login and reads it for every
      # time it shows and for "today". Nothing refreshed it (frontend-seam
      # hunt, 2026-08-25). The residents channel is the one that makes a
      # tab drop every cached month and fetch again, and the month payload
      # is where the new zone can travel.
      community
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      community.update!(timezone: 'America/New_York')

      expect_pushed(residents_channel)
    end

    it 'a resident birthday change pushes the residents channel, because the calendar shows birthdays' do
      resident
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      resident.update!(birthday: Date.new(1980, 6, 5))

      expect_pushed(residents_channel)
    end

    it 'a password change pushes nothing: no screen shows it' do
      resident
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      resident.update!(password: 'new-secret')

      expect(Pusher).not_to have_received(:trigger)
    end
  end

  describe 'writes that jobs and services make' do
    it 'the nightly rotation job pushes the months it adds meals to' do
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      community.rotations.create!(
        color: 'blue', no_email: true,
        meals_attributes: [{ date: Date.new(2026, 5, 20) }, { date: Date.new(2026, 6, 3) }]
      )

      expect_pushed(calendar_channel(Date.new(2026, 5, 1)))
      expect_pushed(calendar_channel(Date.new(2026, 6, 1)))
    end

    it 'a settlement pushes the page of every meal it settles' do
      settled = create(:meal, community: community, date: Date.yesterday)
      create(:bill, meal: settled, resident: resident, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: settled, resident: other_resident, community: community)
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      settle!

      expect(settled.reload).to be_reconciled
      expect_pushed(meal_channel(settled))
    end

    # A birthday moves someone into the adult band with no write at all
    # (Resident#multiplier_on is computed), so there is nothing to push;
    # the SPA refetches its hosts list at midnight instead
    # (data_store_app.js scheduleMidnightRecompute).
  end

  describe 'a meal page also shows its neighbours' do
    # next_id and prev_id come from the meals on either side by date, so
    # adding or removing a meal changes the arrows on its neighbours'
    # pages — the last meal's "next" arrow wakes up when the nightly job
    # adds the next rotation.
    it 'a new meal pushes the pages of the meals before and after it' do
      before = create(:meal, community: community, date: Date.new(2026, 4, 1))
      after = create(:meal, community: community, date: Date.new(2026, 4, 20))
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      create(:meal, community: community, date: Date.new(2026, 4, 10))

      expect_pushed(meal_channel(before))
      expect_pushed(meal_channel(after))
    end

    it 'a deleted meal pushes the pages of the meals before and after it' do
      before = create(:meal, community: community, date: Date.new(2026, 4, 1))
      after = create(:meal, community: community, date: Date.new(2026, 4, 20))
      middle = create(:meal, community: community, date: Date.new(2026, 4, 10))
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      middle.destroy!

      expect_pushed(meal_channel(before))
      expect_pushed(meal_channel(after))
    end
  end

  describe "a rotation's chip runs from its first meal to its last" do
    # So a meal made, deleted or moved at either end of a rotation changes
    # the chip on every month that shows the rotation, also a month whose
    # six weeks do not hold the meal's date (#144). The six weeks of each
    # month used here, Sunday to Saturday:
    #
    #   January 2027    Dec 27 to Feb 6
    #   February 2027   Jan 31 to Mar 13
    #   April 2027      Mar 28 to May 8
    #   September 2027  Aug 29 to Oct 9
    #
    # The rotation has meals on Jan 20 and Feb 3, so January and February
    # show it. A meal on Sep 15 is in a rotation of its own (the factory
    # makes one), so September shows only that rotation.
    let(:rotation) { create(:rotation, community: community) }

    before do
      create(:meal, community: community, rotation: rotation, date: Date.new(2027, 1, 20))
      create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 3))
      create(:meal, community: community, date: Date.new(2027, 9, 15))
    end

    def watch_pushes
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)
    end

    def month_channel(year, month)
      calendar_channel(Date.new(year, month, 1))
    end

    # January's chip now ends on Mar 10, and Mar 10 is not in January's
    # six weeks.
    it 'a new meal after its last meal pushes every month that shows the rotation, and no other' do
      watch_pushes

      create(:meal, community: community, rotation: rotation, date: Date.new(2027, 3, 10))

      expect_pushed(month_channel(2027, 1))
      expect_not_pushed(month_channel(2027, 9))
    end

    # January's chip now ends on Feb 3.
    it 'a deleted last meal pushes every month that showed the rotation' do
      last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 3, 10))
      watch_pushes

      last.destroy!

      expect_pushed(month_channel(2027, 1))
    end

    # February's chip now starts on Jan 20, and Nov 11 is not in
    # February's six weeks.
    it 'a deleted first meal pushes every month that shows the rotation' do
      first = create(:meal, community: community, rotation: rotation, date: Date.new(2026, 11, 11))
      watch_pushes

      first.destroy!

      expect_pushed(month_channel(2027, 2))
    end

    # January's chip now ends on Mar 10 instead of Feb 8. Neither date is
    # in January's six weeks.
    it 'a last meal moved later pushes every month that shows the rotation' do
      last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 8))
      watch_pushes

      last.update!(date: Date.new(2027, 3, 10))

      expect_pushed(month_channel(2027, 1))
    end

    # No form or task moves a meal to another rotation; the console can.
    # Both rotations' chips change: the old one now ends on Feb 3 on
    # January's calendar, and the new one now starts on Mar 10 on April's.
    it 'a meal moved to another rotation pushes the months of both rotations' do
      last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 3, 10))
      other = create(:rotation, community: community)
      create(:meal, community: community, rotation: other, date: Date.new(2027, 4, 14))
      watch_pushes

      last.update!(rotation: other)

      expect_pushed(month_channel(2027, 1))
      expect_pushed(month_channel(2027, 4))
    end

    it 'a meal edit that keeps its date and rotation pushes only its own months' do
      last = create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 8))
      watch_pushes

      last.update!(closed: true)

      expect_pushed(month_channel(2027, 2))
      expect_not_pushed(month_channel(2027, 1))
    end
  end

  describe 'events and reservations that cross months' do
    it 'an event that spans three months pushes the middle month' do
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      create(:event, community: community,
                     start_date: Time.zone.local(2026, 3, 20, 9), end_date: Time.zone.local(2026, 5, 10, 17))

      expect_pushed(calendar_channel(Date.new(2026, 4, 1)))
    end

    it 'an event moved off a month pushes the month it left' do
      event = create(:event, community: community,
                             start_date: Time.zone.local(2026, 3, 20, 9), end_date: Time.zone.local(2026, 3, 20, 17))
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      event.update!(start_date: Time.zone.local(2026, 7, 20, 9), end_date: Time.zone.local(2026, 7, 20, 17))

      expect_pushed(calendar_channel(Date.new(2026, 3, 1)))
      expect_pushed(calendar_channel(Date.new(2026, 7, 1)))
    end
  end

  describe 'the request does not wait for Pusher' do
    let(:token) { resident.keys.first.token }

    # The push is an HTTP call that can take up to 15 seconds to fail,
    # which is rack-timeout's whole budget. It runs in LivePushJob, after
    # the request has answered, so a stalled Pusher cannot turn a
    # committed write into an error on screen.
    it 'a write answers with its push enqueued and Pusher not yet called' do
      token
      meal
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)
      ActiveJob::Base.queue_adapter.perform_enqueued_jobs = false

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'x' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(Pusher).not_to have_received(:trigger)
      expect(LivePushJob).to have_been_enqueued.with(meal_channel(meal), anything, anything)
      expect(LivePushJob).to have_been_enqueued.with(calendar_channel(meal.date), anything, anything)
    end
  end

  describe 'one request, one push' do
    let(:token) { resident.keys.first.token }

    # A request that writes several rows must not send one push per row.
    # The pushes are HTTP calls to Pusher, and the clients would refetch
    # once per push.
    it 'a bills save with several rows pushes the meal page once, excluding the sender' do
      token
      meal
      other_resident
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      patch "/api/v1/meals/#{meal.id}/bills", params: {
        token: token, socket_id: 'sender-socket',
        bills: [
          { resident_id: resident.id, amount: '10.00', no_cost: false },
          { resident_id: other_resident.id, amount: '5.00', no_cost: false }
        ]
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(Pusher).to have_received(:trigger)
        .with(meal_channel(meal), 'update', anything, { socket_id: 'sender-socket' }).once
      expect(Pusher).to have_received(:trigger)
        .with(calendar_channel(meal.date), 'update', anything, any_args).once
    end

    it 'a refused write pushes nothing' do
      token
      meal.update!(reconciliation: create(:reconciliation, community: community))
      RSpec::Mocks.space.proxy_for(Pusher).reset
      calls = []
      allow(Pusher).to receive(:trigger) { |*args| calls << args }

      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'x' }, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(calls).to eq([])
    end
  end
end
