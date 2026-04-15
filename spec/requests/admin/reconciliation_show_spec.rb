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

  it 'renders the meals form with checkboxes wrapped inside a real <form> tag' do
    # Regression test for a bug where form_tag was used inside an Arbre panel
    # block. The form_tag rendered as an empty <form>, while the table and
    # submit button rendered as orphaned children of the panel — outside the
    # form. The Update Meals button silently did nothing because there was no
    # form for it to submit. The fix was to render the form via an ERB partial.
    unit = create(:unit, community: community)
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))

    reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2025, 3, 31))

    get "/reconciliations/#{reconciliation.id}",
        params: { token: token },
        headers: { 'Host' => 'admin.example.com' }

    expect(response).to have_http_status(:ok)

    # Extract the <form> element targeting update_meals and verify the
    # checkbox input is inside it (not orphaned in the surrounding markup).
    form_match = response.body.match(
      %r{<form[^>]+action="/reconciliations/#{reconciliation.id}/update_meals"[^>]*>(.*?)</form>}m
    )
    expect(form_match).not_to be_nil, 'expected an update_meals <form> tag in the rendered HTML'
    expect(form_match[1]).to include(%(name="meal_ids[]"))
    expect(form_match[1]).to include('Update Meals')
  end
end
