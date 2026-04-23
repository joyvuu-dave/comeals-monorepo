# frozen_string_literal: true

require 'rails_helper'

# Regression tests for the reconciled-meal immutability contract. Before these
# guards existed, ActiveAdmin's Bill form would let a superuser rewrite a
# reconciled bill's amount, silently breaking the invariant that reconciled
# records are append-only. The model-layer before_save catches the write; the
# ActiveAdmin controller layer intercepts earlier for better UX.
RSpec.describe 'Admin reconciled immutability' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def build_reconciled_meal(amount: BigDecimal('50'))
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    eater = create(:resident, community: community, unit: unit, multiplier: 2)
    meal = create(:meal, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: amount)
    Reconciliation.create!(community: community, end_date: Time.zone.today)
    { meal: meal.reload, bill: bill.reload, cook: cook, eater: eater }
  end

  describe 'bill edits on a reconciled meal' do
    it 'redirects edit with an alert' do
      bill = build_reconciled_meal[:bill]

      get "/bills/#{bill.id}/edit"

      expect(response).to redirect_to(admin_bill_path(bill))
      expect(flash[:alert]).to match(/reconciled/)
    end

    it 'redirects update with an alert and does not change the amount' do
      bill = build_reconciled_meal[:bill]
      original_amount = bill.amount

      patch "/bills/#{bill.id}", params: { bill: { amount: '999.99' } }

      expect(response).to redirect_to(admin_bill_path(bill))
      expect(flash[:alert]).to match(/reconciled/)
      expect(bill.reload.amount).to eq(original_amount)
    end

    it 'redirects destroy with an alert and does not remove the bill' do
      bill = build_reconciled_meal[:bill]

      expect { delete "/bills/#{bill.id}" }.not_to change(Bill, :count)
      expect(response).to redirect_to(admin_bill_path(bill))
      expect(flash[:alert]).to match(/reconciled/)
    end
  end

  describe 'meal edits on a reconciled meal' do
    it 'redirects edit with an alert' do
      meal = build_reconciled_meal[:meal]

      get "/meals/#{meal.id}/edit"

      expect(response).to redirect_to(admin_meal_path(meal))
      expect(flash[:alert]).to match(/reconciled/)
    end

    it 'redirects update with an alert and does not mutate the meal' do
      meal = build_reconciled_meal[:meal]

      patch "/meals/#{meal.id}", params: { meal: { closed: '1', max: '99' } }

      expect(response).to redirect_to(admin_meal_path(meal))
      expect(flash[:alert]).to match(/reconciled/)
      expect(meal.reload.max).to be_nil
      expect(meal.closed).to be false
    end
  end

  describe 'reconciliation destroy action' do
    it 'has no route — the destroy action is disabled entirely at the resource level' do
      build_reconciled_meal
      recon_id = Reconciliation.last.id

      # actions :all, except: [:destroy] removes the route. A DELETE request
      # produces a RoutingError — which is the correct failure mode for an
      # action that should not exist.
      expect { delete "/reconciliations/#{recon_id}" }
        .to raise_error(ActionController::RoutingError)

      expect(Reconciliation.exists?(recon_id)).to be true
    end
  end
end
