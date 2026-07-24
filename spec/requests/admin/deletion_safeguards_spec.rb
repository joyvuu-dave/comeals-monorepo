# frozen_string_literal: true

require 'rails_helper'

# Admins may delete units and residents created by mistake. The models refuse
# anything harmful: a unit that still has residents, or a resident with ledger
# rows (bills, attendance, guests, settled balances). These specs pin down
# both sides — the refusal, with a flash that says why, and the clean removal.
RSpec.describe 'Admin deletion safeguards' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  describe 'DELETE /units/:id' do
    it 'refuses while the unit has residents and says why' do
      create(:resident, community: community, unit: unit)

      expect { delete "/units/#{unit.id}" }.not_to change(Unit, :count)
      expect(response).to redirect_to(admin_units_path)
      expect(flash[:alert]).to eq('Cannot delete record because dependent residents exist')
    end

    it 'refuses even when every resident in the unit is inactive' do
      create(:resident, community: community, unit: unit, active: false)

      expect { delete "/units/#{unit.id}" }.not_to change(Unit, :count)
      expect(flash[:alert]).to include('residents')
    end

    it 'deletes an empty unit' do
      empty = create(:unit, community: community)

      expect { delete "/units/#{empty.id}" }.to change(Unit, :count).by(-1)
      expect(response).to redirect_to(admin_units_path)
      expect(flash[:notice]).to include('destroyed')
    end
  end

  describe 'DELETE /residents/:id' do
    let(:resident) { create(:resident, community: community, unit: unit) }

    it 'refuses while the resident has a bill and says why' do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      expect { delete "/residents/#{resident.id}" }.not_to change(Resident, :count)
      expect(response).to redirect_to(admin_residents_path)
      expect(flash[:alert]).to eq('Cannot delete record because dependent bills exist')
    end

    it 'refuses while the resident has meal attendance' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect { delete "/residents/#{resident.id}" }.not_to change(Resident, :count)
      expect(flash[:alert]).to eq('Cannot delete record because dependent meal residents exist')
    end

    it 'refuses while the resident has a settled balance' do
      reconciliation = create(:reconciliation, community: community)
      create(:reconciliation_balance, reconciliation: reconciliation, resident: resident)

      expect { delete "/residents/#{resident.id}" }.not_to change(Resident, :count)
      expect(flash[:alert]).to eq('Cannot delete record because dependent reconciliation balances exist')
    end

    it 'deletes a mistake-resident along with their non-ledger records' do
      ResidentBalance.create!(resident: resident, amount: BigDecimal('0'))
      create(:guest_room_reservation, resident: resident, community: community)
      resident_id = resident.id

      expect { delete "/residents/#{resident_id}" }.to change(Resident, :count).by(-1)
      expect(flash[:notice]).to include('destroyed')
      expect(ResidentBalance.where(resident_id: resident_id)).to be_empty
      expect(GuestRoomReservation.where(resident_id: resident_id)).to be_empty
    end
  end

  describe 'DELETE /meals/:id' do
    let(:resident) { create(:resident, community: community, unit: unit) }

    it 'refuses while the meal is closed, says why, and leaves the ledger intact' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))
      meal.update!(closed: true)

      expect { delete "/meals/#{meal.id}" }.not_to change(Meal, :count)
      expect(response).to redirect_to(admin_meal_path(meal))
      expect(flash[:alert]).to eq('Meal has been closed. Reopen it before deleting.')
      expect(Bill.exists?(bill.id)).to be true
    end

    it 'deletes an open meal (a canceled dinner) along with its signups' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect { delete "/meals/#{meal.id}" }.to change(Meal, :count).by(-1)
      expect(flash[:notice]).to include('destroyed')
    end
  end

  describe 'authorization' do
    it 'does not let a non-superuser delete even an empty unit' do
      sign_in create(:admin_user, community: community, superuser: false)
      empty = create(:unit, community: community)

      expect { delete "/units/#{empty.id}" }.not_to change(Unit, :count)
    end
  end
end
