# frozen_string_literal: true

require 'rails_helper'

# Issue #25: admins fix attendance one row at a time, on the meal's page.
# A closed (but unreconciled) meal accepts admin corrections — adjusting
# entries before the billing period closes is normal accounting. A
# reconciled meal refuses absolutely: the books are closed.
RSpec.describe 'Admin attendance correction' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  describe 'adding attendance' do
    it 'adds a resident to a closed, unreconciled meal' do
      meal = create(:meal, community: community)
      meal.update!(closed: true)

      expect do
        post "/meals/#{meal.id}/meal_residents",
             params: { meal_resident: { resident_id: resident.id } }
      end.to change(MealResident, :count).by(1)

      expect(response).to redirect_to("/meals/#{meal.id}")
      row = MealResident.last
      expect(row.meal_id).to eq(meal.id)
      expect(row.resident_id).to eq(resident.id)
      expect(row.multiplier).to eq(resident.multiplier)
    end

    it 'writes one audit row naming the admin' do
      meal = create(:meal, community: community)
      meal.update!(closed: true)

      expect do
        post "/meals/#{meal.id}/meal_residents",
             params: { meal_resident: { resident_id: resident.id } }
      end.to change(Audited::Audit.where(auditable_type: 'MealResident'), :count).by(1)

      audit = Audited::Audit.where(auditable_type: 'MealResident').last
      expect(audit.action).to eq('create')
      expect(audit.user).to eq(admin_user)
    end

    it 'shows a clear error when no resident is chosen' do
      meal = create(:meal, community: community)
      meal.update!(closed: true)

      expect do
        post "/meals/#{meal.id}/meal_residents",
             params: { meal_resident: { resident_id: '' } }
      end.not_to change(MealResident, :count)

      expect(response).to redirect_to("/meals/#{meal.id}")
      expect(flash[:alert]).to include('Resident must exist')
    end
  end

  describe 'removing attendance' do
    it 'removes an original-headcount row from a closed, unreconciled meal' do
      meal = create(:meal, community: community)
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true)

      expect do
        delete "/meals/#{meal.id}/meal_residents/#{row.id}"
      end.to change(MealResident, :count).by(-1)

      expect(response).to redirect_to("/meals/#{meal.id}")

      audit = Audited::Audit.where(auditable_type: 'MealResident', auditable_id: row.id).last
      expect(audit.action).to eq('destroy')
      expect(audit.user).to eq(admin_user)
    end
  end

  describe 'reconciled meals' do
    # Reconciliations only sweep meals with at least one bill.
    def reconcile(meal)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.update!(closed: true)
      Reconciliation.create!(community: community, end_date: Date.yesterday)
      meal.reload
      expect(meal).to be_reconciled
    end

    it 'refuses to add attendance and shows the error' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal,
                             resident: create(:resident, community: community, unit: unit, multiplier: 2),
                             community: community)
      reconcile(meal)

      audits = Audited::Audit.where(auditable_type: 'MealResident')
      audit_count = audits.count

      expect do
        post "/meals/#{meal.id}/meal_residents",
             params: { meal_resident: { resident_id: resident.id } }
      end.not_to change(MealResident, :count)

      expect(audits.count).to eq(audit_count)
      expect(response).to redirect_to("/meals/#{meal.id}")
      expect(flash[:alert]).to include('Meal has been reconciled.')
    end

    it 'refuses to remove attendance and shows the error' do
      meal = create(:meal, community: community)
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      reconcile(meal)

      audits = Audited::Audit.where(auditable_type: 'MealResident')
      audit_count = audits.count

      expect do
        delete "/meals/#{meal.id}/meal_residents/#{row.id}"
      end.not_to change(MealResident, :count)

      expect(audits.count).to eq(audit_count)
      expect(response).to redirect_to("/meals/#{meal.id}")
      expect(flash[:alert]).to include('Meal has been reconciled.')
      expect(MealResident.exists?(row.id)).to be true
    end
  end

  describe 'meal show page controls' do
    it 'offers add and remove controls on an unreconciled meal' do
      meal = create(:meal, community: community)
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true)

      get "/meals/#{meal.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/meals/#{meal.id}/meal_residents\"")
      expect(response.body).to include("/meals/#{meal.id}/meal_residents/#{row.id}")
    end

    it 'hides the controls on a reconciled meal' do
      meal = create(:meal, community: community)
      row = create(:meal_resident, meal: meal, resident: resident, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.update!(closed: true)
      Reconciliation.create!(community: community, end_date: Date.yesterday)
      expect(meal.reload).to be_reconciled

      get "/meals/#{meal.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/meals/#{meal.id}/meal_residents\"")
      expect(response.body).not_to include("/meals/#{meal.id}/meal_residents/#{row.id}")
    end
  end

  describe 'authentication' do
    it 'refuses unauthenticated requests' do
      sign_out admin_user
      meal = create(:meal, community: community)
      meal.update!(closed: true)

      expect do
        post "/meals/#{meal.id}/meal_residents",
             params: { meal_resident: { resident_id: resident.id } }
      end.not_to change(MealResident, :count)

      expect(response).to redirect_to('/login')
    end
  end
end
