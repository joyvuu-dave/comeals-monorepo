# frozen_string_literal: true

require 'rails_helper'

# ADR 0002: the API authorizes by authentication, not ownership. Any signed-in
# resident may act on any other resident's data. That is the deliberate model for
# a high-trust co-housing community, not a hole.
#
# These specs pin the open behavior. If someone later adds a per-record ownership
# check, one of these fails — which is the point: the model should not shift by
# accident. A failure here means "we are changing ADR 0002", not "a test broke".
#
# Actor is `resident`; the data belongs to `other`. Every example acts as the
# actor on the other's records and expects success.
RSpec.describe 'High-trust cross-resident authorization (ADR 0002)' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:other) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'reservations belonging to another resident' do
    it 'creates a guest room reservation in another resident\'s name' do
      post '/api/v1/guest-room-reservations', params: {
        token: token, resident_id: other.id, date: Date.tomorrow.to_s
      }

      expect(response).to have_http_status(:ok)
      expect(GuestRoomReservation.last.resident_id).to eq(other.id)
    end

    it 'updates and reassigns another resident\'s guest room reservation' do
      grr = create(:guest_room_reservation, community: community, resident: other)

      patch "/api/v1/guest-room-reservations/#{grr.id}/update", params: {
        token: token, date: (Time.zone.today + 20).to_s, resident_id: resident.id
      }

      expect(response).to have_http_status(:ok)
      expect(grr.reload.resident_id).to eq(resident.id)
    end

    it 'deletes another resident\'s common house reservation' do
      chr = create(:common_house_reservation, community: community, resident: other)

      expect do
        delete "/api/v1/common-house-reservations/#{chr.id}/delete", params: { token: token }
      end.to change(CommonHouseReservation, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'community events (no owner)' do
    it 'lets any resident delete any event' do
      event = create(:event, community: community)

      expect do
        delete "/api/v1/events/#{event.id}/delete", params: { token: token }
      end.to change(Event, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'meal attendance for another resident' do
    it 'signs another resident up for a meal' do
      meal = create(:meal, community: community)

      expect do
        post "/api/v1/meals/#{meal.id}/residents/#{other.id}", params: {
          token: token, late: false, vegetarian: false
        }
      end.to change { meal.meal_residents.where(resident_id: other.id).count }.by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'bills on a meal the actor did not cook (money path)' do
    it 'lets any resident set the bills on an unreconciled meal' do
      meal = create(:meal, community: community, date: Date.yesterday)
      create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('0'))

      patch "/api/v1/meals/#{meal.id}/bills", params: {
        token: token, meal_id: meal.id,
        bills: [{ resident_id: other.id, amount: '42.00', no_cost: false }]
      }

      expect(response).to have_http_status(:ok)
      expect(meal.bills.find_by(resident_id: other.id).amount).to eq(BigDecimal('42.00'))
    end
  end
end
