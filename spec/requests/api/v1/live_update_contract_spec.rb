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

      settle!(community)

      expect(settled.reload).to be_reconciled
      expect_pushed(meal_channel(settled))
    end
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
