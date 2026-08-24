# frozen_string_literal: true

require 'rails_helper'

# ADR 0004: admin writes are split at the money path, not at read vs write.
# A plain admin runs the community — residents, units, events, reservations,
# rotations. Only a superuser may write anything that changes what somebody
# owes or is owed, or that decides who may act.
#
# spec/models/superuser_adapter_spec.rb proves the adapter logic in isolation;
# this proves ActiveAdmin actually invokes it end-to-end through routing, so
# removing the adapter wiring or a resource opting out would fail a test.
RSpec.describe 'Admin write authorization' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:event) { create(:event, community: community) }

  before { host! 'admin.example.com' }

  # ActiveAdmin denies via a redirect to the admin root with a flash error,
  # not a 403 (on_unauthorized_access is unset, so the default handler runs).
  def expect_denied
    expect(response).to redirect_to('http://admin.example.com/')
    expect(flash[:error]).to eq('You are not authorized to perform this action.')
  end

  context 'when signed in as a plain admin' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it 'may read the index' do
      get '/events'
      expect(response).to have_http_status(:ok)
    end

    describe 'off the money path' do
      it 'may create an event' do
        expect do
          post '/events', params: {
            event: { title: 'Community potluck', start_date: 1.day.from_now,
                     end_date: 1.day.from_now + 2.hours }
          }
        end.to change(Event, :count).by(1)
      end

      it 'may update an event' do
        patch "/events/#{event.id}", params: { event: { title: 'Legit change' } }
        expect(event.reload.title).to eq('Legit change')
      end

      it 'may destroy an event' do
        expect do
          delete "/events/#{event.id}"
        end.to change(Event, :count).by(-1)
      end

      it 'may add a resident, which is the day-to-day job this tier is for' do
        unit = create(:unit, community: community, name: 'Elm')

        expect do
          post '/residents', params: {
            resident: { name: 'New Person', multiplier: 1, unit_id: unit.id,
                        password: '',
                        birthday: 8.years.ago.to_date }
          }
        end.to change(Resident, :count).by(1)
      end
    end

    describe 'on the money path' do
      it 'may not grant the reconciler role: the param is dropped, the resident is saved without it' do
        resident = create(:resident, community: community, unit: unit)

        patch "/residents/#{resident.id}", params: { resident: { can_reconcile: true, name: 'Renamed' } }

        expect(resident.reload.name).to eq('Renamed')
        expect(resident.can_reconcile).to be(false)
      end

      it 'does not see the reconciler checkbox on the form' do
        resident = create(:resident, community: community, unit: unit)
        get "/residents/#{resident.id}/edit"
        expect(response.body).not_to include('resident_can_reconcile')
      end

      it 'may not create a reconciliation' do
        expect do
          post '/reconciliations', params: {
            reconciliation: { end_date: 1.day.ago.to_date }
          }
        end.not_to change(Reconciliation, :count)

        expect_denied
      end

      it 'may not create a bill' do
        meal = create(:meal, community: community)
        resident = create(:resident, community: community, unit: create(:unit, community: community))

        expect do
          post '/bills', params: {
            bill: { meal_id: meal.id, resident_id: resident.id, amount: '25.00' }
          }
        end.not_to change(Bill, :count)

        expect_denied
      end

      it 'may not edit a meal' do
        meal = create(:meal, community: community)

        patch "/meals/#{meal.id}", params: { meal: { max: 12 } }

        expect_denied
        expect(meal.reload.max).not_to eq(12)
      end

      it 'may not change the community cap, which rescales every capped meal' do
        patch "/communities/#{community.id}", params: { community: { cap: '99.00' } }

        expect_denied
        expect(community.reload.cap).not_to eq(BigDecimal('99.00'))
      end
    end
  end

  context 'when signed in as a superuser' do
    before { sign_in create(:admin_user, community: community, superuser: true) }

    it 'may destroy an event' do
      expect do
        delete "/events/#{event.id}"
      end.to change(Event, :count).by(-1)

      expect(response).to redirect_to('/events')
    end

    it 'may grant the reconciler role' do
      resident = create(:resident, community: community, unit: unit)

      patch "/residents/#{resident.id}", params: { resident: { can_reconcile: true } }

      expect(resident.reload.can_reconcile).to be(true)
    end

    it 'may create a reconciliation' do
      # A reconciliation must settle at least one meal, so set one up first.
      unit = create(:unit, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community, date: 1.day.ago.to_date)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))

      expect do
        post '/reconciliations', params: {
          reconciliation: { end_date: 1.day.ago.to_date }
        }
      end.to change(Reconciliation, :count).by(1)
    end
  end
end
