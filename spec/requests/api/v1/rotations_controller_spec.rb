# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Rotations API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/rotations/:id' do
    it 'returns the rotation with cook IDs' do
      rotation = create(:rotation, community: community)
      meal = create(:meal, community: community, rotation: rotation)
      cook = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))

      get "/api/v1/rotations/#{rotation.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['id']).to eq(rotation.id)
      # The only rotation, so its place in date order is 1.
      expect(body['place_value']).to eq(1)
      # The controller passes the rotation's cook ids: the cook with a bill
      # is signed up, and the resident without one is not.
      rows = body['residents'].index_by { |row| row['id'] }
      expect(rows.fetch(cook.id)).to eq('id' => cook.id, 'display_name' => "#{unit.name} - #{cook.name}",
                                        'signed_up' => true)
      expect(rows.fetch(resident.id)['signed_up']).to be(false)
    end

    it 'returns 404 for nonexistent rotation' do
      get '/api/v1/rotations/999999', params: { token: token }
      expect(response).to have_http_status(:not_found)
    end
  end
end
