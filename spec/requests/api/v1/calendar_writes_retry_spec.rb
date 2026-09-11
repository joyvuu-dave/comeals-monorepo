# frozen_string_literal: true

require 'rails_helper'

# The calendar writes — events, guest room reservations, common house
# reservations — run at SERIALIZABLE like everything else (ADR 0005), and
# a reservation's "is this period free?" check is a read before a write,
# which is exactly what PostgreSQL refuses when two of them race. The meal
# writes retry that refusal and answer 409 when it keeps happening; these
# did neither, and answered 500. Found by bin/storm (2026-09-11).
#
# Without a test transaction, because RetryOnConflict does not retry inside
# one.
RSpec.describe 'a calendar write refused for a conflict' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:day) { { start_year: 2026, start_month: 4, start_day: 15 } }
  let(:times) { day.merge(start_hours: 19, start_minutes: 0, end_hours: 21, end_minutes: 0) }

  before { allow(RetryOnConflict).to receive(:sleep) }

  # The database refuses the first write of the given kind, the way a
  # serialization failure arrives: from inside the save, after the values
  # are assigned.
  def refuse_first(klass, method)
    refused = false
    allow_any_instance_of(klass).to receive(method).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance -- the controller loads the record
      if refused
        original.call(*args)
      else
        refused = true
        raise ActiveRecord::SerializationFailure, 'could not serialize access due to read/write dependencies'
      end
    end
  end

  it 'creates the event on the second try' do
    refuse_first(Event, :save)

    post '/api/v1/events', params: { token: token, title: 'Movie Night', description: '', all_day: false, **times }

    expect(response).to have_http_status(:ok)
    expect(Event.where(title: 'Movie Night').count).to eq(1)
  end

  it 'updates the event on the second try' do
    event = create(:event, community: community, title: 'Before')
    refuse_first(Event, :update)

    patch "/api/v1/events/#{event.id}/update", params: { token: token, title: 'After', **times }

    expect(response).to have_http_status(:ok)
    expect(event.reload.title).to eq('After')
  end

  it 'deletes the event on the second try' do
    event = create(:event, community: community)
    refuse_first(Event, :destroy)

    delete "/api/v1/events/#{event.id}/delete", params: { token: token }

    expect(response).to have_http_status(:ok)
    expect(Event.exists?(event.id)).to be(false)
  end

  it 'creates the guest room reservation on the second try' do
    refuse_first(GuestRoomReservation, :save)

    post '/api/v1/guest-room-reservations', params: { token: token, resident_id: resident.id, date: '2026-04-15' }

    expect(response).to have_http_status(:ok)
    expect(GuestRoomReservation.where(date: Date.new(2026, 4, 15)).count).to eq(1)
  end

  it 'creates the common house reservation on the second try' do
    refuse_first(CommonHouseReservation, :save)

    post '/api/v1/common-house-reservations',
         params: { token: token, resident_id: resident.id, title: 'Party', **times }

    expect(response).to have_http_status(:ok)
    expect(CommonHouseReservation.where(title: 'Party').count).to eq(1)
  end

  it 'answers 409 and writes nothing when the conflict does not go away' do
    allow_any_instance_of(CommonHouseReservation).to receive(:save) # rubocop:disable RSpec/AnyInstance -- the refusal happens inside one request
      .and_raise(ActiveRecord::SerializationFailure, 'could not serialize access')

    post '/api/v1/common-house-reservations',
         params: { token: token, resident_id: resident.id, title: 'Party', **times }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['message']).to eq(
      'Someone else was changing the calendar at the same time. Nothing was saved. Try again.'
    )
    expect(CommonHouseReservation.count).to eq(0)
  end
end
