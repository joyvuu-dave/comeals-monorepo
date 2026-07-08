# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Meals API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }

  # ---------------------------------------------------------------------------
  # GET /api/v1/meals
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/meals' do
    it 'returns meals for the community' do
      create(:meal, community: community)

      get '/api/v1/meals', params: { community_id: community.id, token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(1)
    end

    it 'filters by date range when start and end are provided' do
      create(:meal, community: community, date: Date.new(2025, 1, 1))
      create(:meal, community: community, date: Date.new(2025, 6, 1))

      get '/api/v1/meals', params: {
        community_id: community.id,
        token: token,
        start: '2025-05-01',
        end: '2025-07-01'
      }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(1)
    end

    it 'returns 401 without a token' do
      get '/api/v1/meals', params: { community_id: community.id }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ---------------------------------------------------------------------------
  # CSRF safety: API controllers inherit from ActionController::API, which does
  # not include CSRF protection. These tests verify that write operations work
  # with token auth alone — no CSRF token required. This is the safety net for
  # removing `skip_before_action :verify_authenticity_token` from
  # ApplicationController (which only needs to affect ActiveAdmin, not the API).
  # ---------------------------------------------------------------------------
  describe 'API write operations work without CSRF tokens' do
    let(:meal) { create(:meal, community: community) }

    it 'POST (create_meal_resident) succeeds with just an auth token' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
           params: { token: token, late: false, vegetarian: false }

      expect(response).to have_http_status(:ok)
    end

    it 'PATCH (update_description) succeeds with just an auth token' do
      patch "/api/v1/meals/#{meal.id}/description",
            params: { token: token, description: 'Test menu' }

      expect(response).to have_http_status(:ok)
    end

    it 'DELETE (destroy_meal_resident) succeeds with just an auth token' do
      create(:meal_resident, meal: meal, resident: resident, community: community)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
             params: { token: token }

      expect(response).to have_http_status(:ok)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/meals/next
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/meals/next' do
    it 'returns the next upcoming meal' do
      future_meal = create(:meal, community: community, date: Time.zone.today + 1)

      get '/api/v1/meals/next', params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['meal_id']).to eq(future_meal.id)
    end

    it 'returns 400 when no future meals exist' do
      create(:meal, community: community, date: Date.yesterday)

      get '/api/v1/meals/next', params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['meal_id']).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/meals/:meal_id
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/meals/:meal_id' do
    it 'returns the meal' do
      meal = create(:meal, community: community)

      get "/api/v1/meals/#{meal.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 for nonexistent meal' do
      get '/api/v1/meals/999999', params: { token: token }

      expect(response).to have_http_status(:not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/meals/:meal_id/history
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/meals/:meal_id/history' do
    it 'returns audit history for the meal' do
      meal = create(:meal, community: community)

      get "/api/v1/meals/#{meal.id}/history", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to have_key('date')
      expect(body).to have_key('items')
    end

    # Admin attendance corrections (issue #25) put AdminUser rows in the
    # audit trail. The serializer renders the audit user's name, so an
    # admin-made audit must not break the resident-facing history.
    it 'renders audits made by an admin user' do
      meal = create(:meal, community: community)
      admin = create(:admin_user, community: community)
      Audited.audit_class.as_user(admin) do
        create(:meal_resident, meal: meal, resident: resident, community: community)
      end

      get "/api/v1/meals/#{meal.id}/history", params: { token: token }

      expect(response).to have_http_status(:ok)
      items = response.parsed_body['items']
      expect(items).not_to be_empty
      expect(items.first['user_name']).to eq(admin.email)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/meals/:meal_id/residents/:resident_id (create_meal_resident)
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/meals/:meal_id/residents/:resident_id' do
    let(:meal) { create(:meal, community: community) }

    it 'signs up a resident for a meal' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      expect(response).to have_http_status(:ok)
      expect(meal.meal_residents.find_by(resident: resident)).to be_present

      body = response.parsed_body
      expect(body).to have_key('id')
      expect(body).to have_key('meal_id')
      expect(body).to have_key('resident_id')
      expect(body).to have_key('late')
      expect(body).to have_key('vegetarian')
      expect(body).to have_key('created_at')
      expect(body).not_to have_key('multiplier')
      expect(body).not_to have_key('community_id')
      expect(body).not_to have_key('updated_at')
    end

    it 'copies the resident multiplier to the meal_resident' do
      resident.update!(multiplier: 1)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      mr = meal.meal_residents.find_by(resident: resident)
      expect(mr.multiplier).to eq(1)
    end

    it 'sets late and vegetarian flags' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token,
        late: true,
        vegetarian: true
      }

      mr = meal.meal_residents.find_by(resident: resident)
      expect(mr.late).to be(true)
      expect(mr.vegetarian).to be(true)
    end

    it 'is idempotent — re-signing up updates instead of erroring' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }
      expect(response).to have_http_status(:ok)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: true, vegetarian: false
      }
      expect(response).to have_http_status(:ok)

      expect(meal.meal_residents.where(resident: resident).count).to eq(1)
      expect(meal.meal_residents.find_by(resident: resident).late).to be(true)
    end

    it 'attributes the audit row to the authenticated resident' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      expect(response).to have_http_status(:ok)
      audit = Audited::Audit.where(auditable_type: 'MealResident').last
      expect(audit.action).to eq('create')
      expect(audit.user).to eq(resident)
    end

    it 'rejects signup when meal is closed without max' do
      meal.update!(closed: true)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      expect(response).to have_http_status(:bad_request)
      expect(meal.meal_residents.find_by(resident: resident)).to be_nil
    end

    # The admin_correction escape hatch (issue #25) belongs to the admin
    # controller alone. A resident smuggling the flag as a param must still
    # hit the closed-meal freeze.
    it 'ignores an admin_correction param — the freeze still applies' do
      meal.update!(closed: true)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false, admin_correction: true
      }

      expect(response).to have_http_status(:bad_request)
      expect(meal.meal_residents.find_by(resident: resident)).to be_nil
    end

    it 'rejects signup when meal is at max capacity' do
      other = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: other, community: community)
      meal.update!(closed: true, max: 1)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      expect(response).to have_http_status(:bad_request)
    end

    it 'allows signup when meal is closed but has open extras spots' do
      meal.update!(closed: true, max: 5)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token, late: false, vegetarian: false
      }

      expect(response).to have_http_status(:ok)
      expect(meal.meal_residents.find_by(resident: resident)).to be_present
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/v1/meals/:meal_id/residents/:resident_id (destroy_meal_resident)
  # ---------------------------------------------------------------------------
  describe 'DELETE /api/v1/meals/:meal_id/residents/:resident_id' do
    let(:meal) { create(:meal, community: community) }

    it 'removes a resident from a meal' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(MealResident.find_by(id: mr.id)).to be_nil
    end

    # Issue #22: a guard-blocked destroy must surface as a 400 with the
    # guard's message, not a 500 (mirrors destroy_guest).
    it 'blocks removal from a closed meal when resident signed up before closing' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Meal has been closed.')
      expect(MealResident.exists?(mr.id)).to be true
    end

    it 'returns 404 when meal_resident does not exist' do
      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token }

      expect(response).to have_http_status(:not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /api/v1/meals/:meal_id/residents/:resident_id (update_meal_resident)
  # ---------------------------------------------------------------------------
  describe 'PATCH /api/v1/meals/:meal_id/residents/:resident_id' do
    let(:meal) { create(:meal, community: community) }
    let!(:meal_resident) { create(:meal_resident, meal: meal, resident: resident, community: community) }

    it 'updates late and vegetarian flags' do
      patch "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: {
        token: token,
        late: true,
        vegetarian: true
      }

      expect(response).to have_http_status(:ok)
      meal_resident.reload
      expect(meal_resident.late).to be(true)
      expect(meal_resident.vegetarian).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/meals/:meal_id/residents/:resident_id/guests (create_guest)
  # ---------------------------------------------------------------------------
  describe 'POST /api/v1/meals/:meal_id/residents/:resident_id/guests' do
    let(:meal) { create(:meal, community: community) }

    it 'adds a guest to the meal' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: {
        token: token,
        vegetarian: false
      }

      expect(response).to have_http_status(:ok)
      expect(meal.guests.count).to eq(1)
      expect(meal.guests.first.resident).to eq(resident)

      body = response.parsed_body
      expect(body).to have_key('id')
      expect(body).to have_key('meal_id')
      expect(body).to have_key('resident_id')
      expect(body).to have_key('vegetarian')
      expect(body).to have_key('created_at')
      expect(body['meal_id']).to eq(meal.id)
      expect(body['resident_id']).to eq(resident.id)
      expect(body).not_to have_key('name')
      expect(body).not_to have_key('multiplier')
      expect(body).not_to have_key('late')
      expect(body).not_to have_key('updated_at')
    end

    it 'sets the vegetarian flag on the guest' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: {
        token: token,
        vegetarian: true
      }

      expect(meal.guests.first.vegetarian).to be(true)
    end

    it 'rejects guest when meal is closed without max' do
      meal.update!(closed: true)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: {
        token: token,
        vegetarian: false
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Meal has been closed.')
      expect(meal.guests.count).to eq(0)
    end

    it 'rejects guest when meal is at max capacity' do
      other = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: other, community: community)
      meal.update!(closed: true, max: 1)

      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests", params: {
        token: token,
        vegetarian: false
      }

      expect(response).to have_http_status(:bad_request)
      expect(meal.guests.count).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id
  # ---------------------------------------------------------------------------
  describe 'DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id' do
    let(:meal) { create(:meal, community: community) }

    it 'removes a guest from the meal' do
      guest = create(:guest, meal: meal, resident: resident)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}", params: {
        token: token
      }

      expect(response).to have_http_status(:ok)
      expect(Guest.find_by(id: guest.id)).to be_nil
    end

    it 'returns 404 for nonexistent guest' do
      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/999999", params: {
        token: token
      }

      expect(response).to have_http_status(:not_found)
    end

    # Issue #5 failure scenario: removing a guest after the meal closed
    # shifts every other attendee's charge. The API must reject it.
    it 'blocks removal from a closed meal when guest was added before closing' do
      guest = create(:guest, meal: meal, resident: resident)
      meal.update!(closed: true)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}", params: {
        token: token
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Meal has been closed.')
      expect(Guest.find_by(id: guest.id)).to be_present
    end

    it 'allows removal from a closed meal when guest was added after closing' do
      meal.update_columns(closed: true, closed_at: 1.hour.ago, max: 5)
      guest = create(:guest, meal: meal, resident: resident)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}", params: {
        token: token
      }

      expect(response).to have_http_status(:ok)
      expect(Guest.find_by(id: guest.id)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Reconciled meal immutability (Regression test for BUG-2)
  # CLAUDE.md rule 7: "Once a meal is reconciled, its bills and attendance
  # cannot change." update_bills already enforces this; these tests verify
  # the same guard exists on attendance and metadata endpoints.
  # ---------------------------------------------------------------------------
  describe 'reconciled meal immutability' do
    let(:reconciliation) { create(:reconciliation, community: community) }
    let(:meal) { create(:meal, community: community) }

    # Bypasses callbacks — Meal itself has no before_save guard, and children
    # (MealResident, Guest, Bill) now reject any save when meal.reconciled?,
    # so once this runs no new children can be created via normal model paths.
    def reconcile!
      meal.update_columns(reconciliation_id: reconciliation.id)
    end

    it 'blocks create_meal_resident on a reconciled meal' do
      reconcile!
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
           params: { token: token, late: false, vegetarian: false }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(meal.meal_residents.count).to eq(0)
    end

    it 'blocks destroy_meal_resident on a reconciled meal' do
      mr = MealResident.create!(meal: meal, resident: resident, community: community, multiplier: 2)
      reconcile!

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
             params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(MealResident.find_by(id: mr.id)).to be_present
    end

    it 'blocks update_meal_resident on a reconciled meal' do
      MealResident.create!(meal: meal, resident: resident, community: community, multiplier: 2)
      reconcile!

      patch "/api/v1/meals/#{meal.id}/residents/#{resident.id}",
            params: { token: token, late: true }

      expect(response).to have_http_status(:bad_request)
    end

    it 'blocks create_guest on a reconciled meal' do
      reconcile!
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests",
           params: { token: token, vegetarian: false }

      expect(response).to have_http_status(:bad_request)
      expect(meal.guests.count).to eq(0)
    end

    it 'blocks destroy_guest on a reconciled meal' do
      guest = Guest.create!(meal: meal, resident: resident, multiplier: 2)
      reconcile!

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}",
             params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(Guest.find_by(id: guest.id)).to be_present
    end

    it 'blocks update_description on a reconciled meal' do
      reconcile!
      patch "/api/v1/meals/#{meal.id}/description",
            params: { token: token, description: 'Should not change' }

      expect(response).to have_http_status(:bad_request)
      expect(meal.reload.description).not_to eq('Should not change')
    end

    it 'blocks update_max on a reconciled meal' do
      reconcile!
      patch "/api/v1/meals/#{meal.id}/max",
            params: { token: token, max: 99 }

      expect(response).to have_http_status(:bad_request)
      expect(meal.reload.max).not_to eq(99)
    end

    it 'blocks update_closed on a reconciled meal' do
      reconcile!
      patch "/api/v1/meals/#{meal.id}/closed",
            params: { token: token, closed: true }

      expect(response).to have_http_status(:bad_request)
    end
  end

  # ---------------------------------------------------------------------------
  # Reconciliation racing the mutation endpoints (issue #6)
  # The reject_if_reconciled before_action reads the meal before any lock is
  # taken. `rake reconciliations:create` runs in a separate process, so its
  # sweep can commit mid-request. Every mutation must take the meal row lock
  # and re-check reconciled? on the lock's fresh reload — a write that slips
  # through is excluded from the settlement yet frozen afterwards, so the
  # ledger stops being reconstructible from source data.
  # ---------------------------------------------------------------------------
  describe 'reconciliation racing the mutation endpoints' do
    let(:meal) { create(:meal, community: community) }

    before do
      # end_date predates the meal so creating the reconciliation does not
      # sweep it; the with_lock wrapper below performs the sweep inside the
      # race window instead (update_all, like the real assign_meals). An
      # endpoint that never takes the lock never triggers the sweep and
      # wrongly succeeds — that also fails the 400 expectation.
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)

      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end
    end

    it 'destroy_meal_resident returns 400 and keeps the row when the meal is swept mid-request' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(MealResident.exists?(mr.id)).to be true
    end

    it 'update_meal_resident returns 400 and keeps the flags when the meal is swept mid-request' do
      mr = create(:meal_resident, meal: meal, resident: resident, community: community, late: false)

      patch "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(mr.reload.late).to be(false)
    end

    # set_guest loads through @meal.guests, so inverse_of pins the guest's
    # meal to the request-start snapshot — without the lock's reload the
    # model guard structurally cannot see a mid-request sweep.
    it 'destroy_guest returns 400 and keeps the guest when the meal is swept mid-request' do
      guest = create(:guest, meal: meal, resident: resident)

      delete "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}", params: { token: token }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(Guest.exists?(guest.id)).to be true
    end

    it 'update_max returns 400 and keeps max when the meal is swept mid-request' do
      meal.update!(closed: true)

      patch "/api/v1/meals/#{meal.id}/max", params: { token: token, max: 10 }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(meal.reload.max).to be_nil
    end

    it 'update_description returns 400 and keeps the description when the meal is swept mid-request' do
      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Late edit' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(meal.reload.description).not_to eq('Late edit')
    end

    it 'update_closed returns 400 and keeps the meal open when the meal is swept mid-request' do
      patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(meal.reload.closed).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/meals/:meal_id/cooks
  # ---------------------------------------------------------------------------
  describe 'GET /api/v1/meals/:meal_id/cooks' do
    it 'returns meal form data with residents and bills' do
      meal = create(:meal, community: community)

      get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to have_key('id')
      expect(body).to have_key('residents')
      expect(body).to have_key('bills')
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /api/v1/meals/:meal_id/description
  # ---------------------------------------------------------------------------
  describe 'PATCH /api/v1/meals/:meal_id/description' do
    let(:meal) { create(:meal, community: community) }

    it 'updates the meal description' do
      patch "/api/v1/meals/#{meal.id}/description", params: {
        token: token,
        description: 'Pasta night'
      }

      expect(response).to have_http_status(:ok)
      expect(meal.reload.description).to eq('Pasta night')
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /api/v1/meals/:meal_id/max
  # ---------------------------------------------------------------------------
  describe 'PATCH /api/v1/meals/:meal_id/max' do
    let(:meal) { create(:meal, community: community) }

    it 'updates the meal max capacity on a closed meal' do
      meal.update!(closed: true)

      patch "/api/v1/meals/#{meal.id}/max", params: {
        token: token,
        max: 10
      }

      expect(response).to have_http_status(:ok)
      expect(meal.reload.max).to eq(10)
    end

    it 'rejects max below current attendees count' do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true)

      patch "/api/v1/meals/#{meal.id}/max", params: {
        token: token,
        max: 0
      }

      expect(response).to have_http_status(:bad_request)
    end

    # A close request that failed can leave the client sending a cap for a
    # meal the server still sees as open. Before this guard, before_save
    # nilled the cap and the client got a 200 for a cap that was never set.
    it 'rejects a cap while the meal is open' do
      patch "/api/v1/meals/#{meal.id}/max", params: {
        token: token,
        max: 10
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('open')
      expect(meal.reload.max).to be_nil
    end

    it 'allows clearing max while the meal is open' do
      # JSON body so max arrives as a real null, exactly as the client sends it
      patch "/api/v1/meals/#{meal.id}/max",
            params: { token: token, max: nil }.to_json,
            headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(meal.reload.max).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # PATCH /api/v1/meals/:meal_id/closed
  # ---------------------------------------------------------------------------
  describe 'PATCH /api/v1/meals/:meal_id/closed' do
    let(:meal) { create(:meal, community: community) }

    it 'closes a meal' do
      patch "/api/v1/meals/#{meal.id}/closed", params: {
        token: token,
        closed: true
      }

      expect(response).to have_http_status(:ok)
      meal.reload
      expect(meal.closed).to be(true)
      expect(meal.closed_at).to be_present
    end

    it 'reopens a meal and clears max' do
      meal.update!(closed: true, max: 5)

      patch "/api/v1/meals/#{meal.id}/closed", params: {
        token: token,
        closed: false
      }

      expect(response).to have_http_status(:ok)
      meal.reload
      expect(meal.closed).to be(false)
      expect(meal.closed_at).to be_nil
      expect(meal.max).to be_nil
    end
  end
end
