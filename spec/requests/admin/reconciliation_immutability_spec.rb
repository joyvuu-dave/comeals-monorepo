# frozen_string_literal: true

require 'rails_helper'

# Reconciliations are append-only settlement events (issue #4). Once created —
# and cooks emailed their amounts — ActiveAdmin must expose no route that can
# rewrite one: no end_date edit (the cutoff is the invariant defining which
# meals were swept) and no update_meals (which un-reconciled meals via
# update_all with no audit trail, then rewrote the settled balances in place).
# Corrections settle as new entries in the next reconciliation.
RSpec.describe 'Admin Reconciliation Immutability' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def create_settled_reconciliation
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)

    meal = create(:meal, community: community, date: Date.new(2025, 3, 1))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))

    settle!(community, cutoff: Date.new(2025, 3, 31))
  end

  it 'exposes no update_meals route — the settled meal set cannot be rewritten' do
    reconciliation = create_settled_reconciliation
    meal = reconciliation.meals.sole

    expect do
      patch "/reconciliations/#{reconciliation.id}/update_meals", params: { meal_ids: [] }
    end.to raise_error(ActionController::RoutingError)

    expect(meal.reload.reconciliation_id).to eq(reconciliation.id)
  end

  it 'exposes no update route — end_date is frozen after settlement' do
    reconciliation = create_settled_reconciliation

    expect do
      patch "/reconciliations/#{reconciliation.id}",
            params: { reconciliation: { end_date: Date.new(2025, 4, 30) } }
    end.to raise_error(ActionController::RoutingError)

    expect(reconciliation.reload.end_date).to eq(Date.new(2025, 3, 31))
  end

  it 'exposes no edit route' do
    reconciliation = create_settled_reconciliation

    expect do
      get "/reconciliations/#{reconciliation.id}/edit"
    end.to raise_error(ActionController::RoutingError)
  end

  it 'still renders the new-reconciliation form' do
    get '/reconciliations/new'

    expect(response).to have_http_status(:ok)
  end

  # The form is the only way left to create an empty reconciliation: the
  # nightly reconciliations:create task already skips when nothing is eligible.
  # Because the table is append-only, an empty one could never be removed —
  # it would sit in the list and in every resident's history as a settlement
  # that settled nothing, and it would become the Reconciliation.last that
  # reconciliations:send_cooking_slot_email mails cooks about.
  it 'refuses a reconciliation that would settle no meals' do
    expect do
      post '/reconciliations',
           params: { reconciliation: { end_date: Date.yesterday } }
    end.not_to change(Reconciliation, :count)

    expect(response.body).to include('must settle at least one meal')
  end

  it 'still allows creating the next reconciliation — corrections are new entries' do
    # The form refuses a reconciliation that would settle nothing, so give the
    # next period a meal to settle.
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community, date: Date.yesterday)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    expect do
      post '/reconciliations',
           params: { reconciliation: { end_date: Date.yesterday } }
    end.to change(Reconciliation, :count).by(1)

    # The form must settle, not just insert a row: the meal is claimed and
    # the ledger tables are written.
    reconciliation = Reconciliation.order(:id).last
    expect(reconciliation.meals).to contain_exactly(meal)
    expect(reconciliation.reconciliation_balances.pluck(:resident_id)).to contain_exactly(cook.id, eater.id)
    expect(MealCharge.for_reconciliation(reconciliation).count).to eq(2)
  end
end
