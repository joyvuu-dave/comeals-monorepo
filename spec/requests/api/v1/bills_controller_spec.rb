# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bills API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  describe 'GET /api/v1/bills/:id' do
    it 'returns the bill' do
      cook = create(:resident, community: community, unit: unit)
      meal = create(:meal, community: community)
      bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))

      get "/api/v1/bills/#{bill.id}", params: {
        token: token
      }

      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 for nonexistent bill' do
      get '/api/v1/bills/999999', params: {
        token: token
      }

      expect(response).to have_http_status(:not_found)
    end
  end
end
