# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin Reconciliation Show' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:token) { 'test-readonly-token' }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin_user.id.to_s)
  end

  it 'renders the show page with unit balances panel' do
    unit = create(:unit, community: community, name: 'Elm')
    resident = create(:resident, community: community, unit: unit)

    reconciliation = create(:reconciliation, community: community)
    create(:reconciliation_balance,
           reconciliation: reconciliation,
           resident: resident,
           amount: BigDecimal('42.50'))

    get "/reconciliations/#{reconciliation.id}",
        params: { token: token },
        headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Unit Balances')
    expect(response.body).to include('Elm')
    expect(response.body).to include('$42.50')
  end
end
