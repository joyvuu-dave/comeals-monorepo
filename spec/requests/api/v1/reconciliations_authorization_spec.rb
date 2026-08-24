# frozen_string_literal: true

require 'rails_helper'

# Settling through the API is for the person who does the books (#72). A
# resident token never expires and the app runs on a shared screen, so
# "logged in" is not enough: the resident needs can_reconcile, which only
# a superuser grants in admin.
RSpec.describe 'reconciliation endpoints need the reconciler role' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    meal = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
  end

  def headers_for(resident)
    { 'Authorization' => "Bearer #{resident.keys.first.token}" }
  end

  context 'with a resident who does not have the role' do
    let(:resident) { create(:resident, community: community, unit: unit) }

    it 'refuses the preview' do
      get '/api/v1/reconciliations/preview', params: { cutoff: Date.yesterday.to_s }, headers: headers_for(resident)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['message']).to include('reconciler role')
    end

    it 'refuses to settle, and writes nothing' do
      expect do
        post '/api/v1/reconciliations', params: { cutoff: Date.yesterday.to_s }, headers: headers_for(resident)
      end.not_to change(Reconciliation, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'with a resident who has the role' do
    let(:resident) { create(:resident, community: community, unit: unit, can_reconcile: true) }

    it 'allows the preview and the settlement' do
      get '/api/v1/reconciliations/preview', params: { cutoff: Date.yesterday.to_s }, headers: headers_for(resident)
      expect(response).to have_http_status(:ok)

      post '/api/v1/reconciliations', params: { cutoff: Date.yesterday.to_s }, headers: headers_for(resident)
      expect(response).to have_http_status(:created)
    end
  end

  it 'still answers 401, not 403, with no token at all' do
    get '/api/v1/reconciliations/preview', params: { cutoff: Date.yesterday.to_s }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'defaults to no role for a new resident' do
    expect(create(:resident, community: community, unit: unit).can_reconcile).to be(false)
  end
end
