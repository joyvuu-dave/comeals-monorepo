# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'PATCH /api/v1/meals/:meal_id/bills' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let!(:bill) { create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0')) }

  def update_bills(meal_id:, bills:, token: self.token)
    patch "/api/v1/meals/#{meal_id}/bills", params: {
      meal_id: meal_id,
      bills: bills,
      token: token
    }
  end

  describe 'successful bill update' do
    it 'updates bill amounts and returns 200' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '75.50', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')

      bill.reload
      expect(bill.amount).to eq(BigDecimal('75.50'))
      expect(bill.no_cost).to be(false)
    end

    it 'returns the persisted bills so the client can display what was stored' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '75.50', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      # Rails encodes BigDecimal as a string and drops trailing zeros.
      expect(response.parsed_body['bills']).to contain_exactly(
        { 'resident_id' => cook.id, 'amount' => '75.5', 'no_cost' => false }
      )
    end

    it 'stores amount as BigDecimal with full precision' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '50.01', no_cost: false }]
      )

      bill.reload
      expect(bill.amount).to be_a(BigDecimal)
      expect(bill.amount).to eq(BigDecimal('50.01'))
    end

    it 'handles multiple cooks' do
      cook_2 = create(:resident, community: community, unit: unit)

      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '30.00', no_cost: false },
          { resident_id: cook_2.id, amount: '20.00', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(2)

      expect(meal.bills.find_by(resident: cook).amount).to eq(BigDecimal('30'))
      expect(meal.bills.find_by(resident: cook_2).amount).to eq(BigDecimal('20'))
    end

    it 'adds a new cook when a new resident_id is included' do
      new_cook = create(:resident, community: community, unit: unit)

      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '40.00', no_cost: false },
          { resident_id: new_cook.id, amount: '25.00', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(2)
      expect(meal.bills.find_by(resident: new_cook).amount).to eq(BigDecimal('25'))
    end
  end

  describe 'no_cost bills' do
    it 'sets no_cost flag on the bill' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '0', no_cost: true }]
      )

      expect(response).to have_http_status(:ok)
      bill.reload
      expect(bill.no_cost).to be(true)
      expect(bill.amount).to eq(BigDecimal('0'))
    end

    it 'excludes no_cost bills from total_cost' do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      paying_cook = create(:resident, community: community, unit: unit)

      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '0', no_cost: true },
          { resident_id: paying_cook.id, amount: '60.00', no_cost: false }
        ]
      )

      meal.reload
      expect(meal.total_cost).to eq(BigDecimal('60'))
    end
  end

  describe 'reconciled meal rejection' do
    let(:reconciliation) { create(:reconciliation, community: community) }

    before do
      meal.update!(reconciliation: reconciliation)
    end

    it 'returns 400 with an error message' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '50.00', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
    end

    it 'does not modify the bill' do
      original_amount = bill.amount

      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '999.00', no_cost: false }]
      )

      bill.reload
      expect(bill.amount).to eq(original_amount)
    end
  end

  describe 'removing a cook' do
    it 'destroys the omitted cook’s bill and records the removal in the meal history' do
      departing_cook = create(:resident, community: community, unit: unit)
      departing_bill = create(:bill, meal: meal, resident: departing_cook, community: community,
                                     amount: BigDecimal('80'))

      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '20.00', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      expect(meal.bills.pluck(:resident_id)).to contain_exactly(cook.id)

      destroy_audit = meal.associated_audits.find_by(auditable_type: 'Bill', auditable_id: departing_bill.id,
                                                     action: 'destroy')
      expect(destroy_audit).not_to be_nil
      expect(BigDecimal(destroy_audit.audited_changes['amount'].to_s)).to eq(BigDecimal('80'))
    end

    it 'destroys every bill when all cook slots are cleared' do
      # as: :json — an empty array survives JSON parsing (the SPA sends JSON);
      # form encoding would drop the bills key entirely.
      patch "/api/v1/meals/#{meal.id}/bills",
            params: { meal_id: meal.id, bills: [], token: token },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(0)
      expect(meal.associated_audits.where(auditable_type: 'Bill', action: 'destroy').count).to eq(1)
    end
  end

  describe 'reconciliation racing the locked write' do
    # The reject_if_reconciled before_action reads the meal before the lock is
    # taken, so a reconciliation sweep can commit in between. The locked write
    # must then re-encounter the guards and roll back — a swept meal's bills
    # may never be deleted.
    it 'returns 400 and keeps the bills when the meal is swept after the stale check' do
      # end_date predates the meal so creating the reconciliation does not
      # sweep it; the with_lock wrapper below performs the sweep inside the
      # race window instead (update_all, like the real assign_meals).
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)

      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end

      patch "/api/v1/meals/#{meal.id}/bills",
            params: { meal_id: meal.id, bills: [], token: token },
            as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(Bill.exists?(bill.id)).to be true
    end

    # The destroy-path pin above survives on the guard's raise alone; the
    # upsert path (no bills removed) needs the post-lock reconciled? re-check
    # to reject cleanly instead of erroring on the before_save guard.
    it 'returns 400 and keeps the amounts when only upserts race the sweep' do
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)

      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end

      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '999.00', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('reconciled')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end
  end

  describe 'blank amount' do
    it 'treats empty string amount as zero' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      bill.reload
      expect(bill.amount).to eq(BigDecimal('0'))
    end

    it 'treats nil amount as zero' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: nil, no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      bill.reload
      expect(bill.amount).to eq(BigDecimal('0'))
    end
  end

  describe 'duplicate cook rejection' do
    it 'returns 400 with the cook id in the message' do
      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '30.00', no_cost: false },
          { resident_id: cook.id, amount: '40.00', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("Duplicate cook in bills: resident ##{cook.id}.")
    end

    it 'does not modify the bill' do
      original_amount = bill.amount

      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '999.00', no_cost: false },
          { resident_id: cook.id, amount: '888.00', no_cost: false }
        ]
      )

      bill.reload
      expect(bill.amount).to eq(original_amount)
    end
  end

  describe 'negative amount' do
    # The whole-cents grammar has no minus sign, so the controller rejects
    # a negative amount before any DB write.
    it 'returns 400 and leaves the bill unchanged' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '-5.00', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end
  end

  describe 'whole-cents grammar' do
    # Issue #29: amounts are whole cents, 0 to 9999.99. Reject, never round —
    # a sub-cent amount must not enter the ledger, and the server must not
    # invent a different value than the cook typed.
    it 'returns 400 for a sub-cent amount and leaves the bill unchanged' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '12.345', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    it 'returns 400 for an amount over 9999.99 instead of overflowing the column' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '10000', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    it 'does not include bills in a rejection — no rows were written' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '12.345', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).not_to have_key('bills')
    end

    it 'returns 400 for scientific notation' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '1e3', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
    end

    it 'returns 400 for a sub-cent fraction that would round to zero' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '0.000000001', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
    end

    it 'accepts the largest whole-cent amount the column can hold' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '9999.99', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('9999.99'))
    end

    it 'accepts a single decimal digit' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '12.5', no_cost: false }]
      )

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('12.5'))
    end
  end

  describe 'untouched rows' do
    # A row with only resident_id names a cook the user did not touch. It
    # keeps the bill alive (a cook left out of the payload is removed) but
    # must never rewrite the stored amount or no_cost — this is what stops
    # a client display value from silently changing a financial record.
    it 'keeps the stored amount and no_cost when only resident_id is sent' do
      bill.update!(amount: BigDecimal('12.34'), no_cost: false)
      untouched_at = bill.reload.updated_at
      new_cook = create(:resident, community: community, unit: unit)

      patch "/api/v1/meals/#{meal.id}/bills",
            params: {
              meal_id: meal.id,
              bills: [
                { resident_id: cook.id },
                { resident_id: new_cook.id, amount: '5.00', no_cost: false }
              ],
              token: token
            },
            as: :json

      expect(response).to have_http_status(:ok)
      bill.reload
      expect(bill.amount).to eq(BigDecimal('12.34'))
      expect(bill.no_cost).to be(false)
      expect(bill.updated_at).to eq(untouched_at)
      expect(meal.bills.find_by(resident: new_cook).amount).to eq(BigDecimal('5'))
    end

    it 'returns the stored values for untouched rows, not what the client displayed' do
      bill.update!(amount: BigDecimal('12.34'), no_cost: false)
      new_cook = create(:resident, community: community, unit: unit)

      patch "/api/v1/meals/#{meal.id}/bills",
            params: {
              meal_id: meal.id,
              bills: [
                { resident_id: cook.id },
                { resident_id: new_cook.id, amount: '5.00', no_cost: false }
              ],
              token: token
            },
            as: :json

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body['bills']
      expect(rows).to contain_exactly(
        { 'resident_id' => cook.id, 'amount' => '12.34', 'no_cost' => false },
        { 'resident_id' => new_cook.id, 'amount' => '5.0', 'no_cost' => false }
      )
    end

    it 'creates a bill with column defaults for a new cook sent without values' do
      new_cook = create(:resident, community: community, unit: unit)

      patch "/api/v1/meals/#{meal.id}/bills",
            params: {
              meal_id: meal.id,
              bills: [
                { resident_id: cook.id },
                { resident_id: new_cook.id }
              ],
              token: token
            },
            as: :json

      expect(response).to have_http_status(:ok)
      new_bill = meal.bills.find_by(resident: new_cook)
      expect(new_bill.amount).to eq(BigDecimal('0'))
      expect(new_bill.no_cost).to be(false)
    end

    it 'does not validate the stored value of an untouched row' do
      # The stored amount is grammar-valid by construction (CHECK
      # constraint), so an untouched row must save cleanly even while
      # another row in the same payload changes.
      bill.update!(amount: BigDecimal('9999.99'))
      new_cook = create(:resident, community: community, unit: unit)

      patch "/api/v1/meals/#{meal.id}/bills",
            params: {
              meal_id: meal.id,
              bills: [
                { resident_id: cook.id },
                { resident_id: new_cook.id, amount: '1.00', no_cost: false }
              ],
              token: token
            },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('9999.99'))
    end
  end

  describe 'partial failure in a multi-bill payload' do
    # Atomicity rests on with_lock's implicit transaction. The bills are
    # written in payload order, so the first bill has already been updated
    # when the second one fails validation. The transaction must roll that
    # write back — a 400 response must mean nothing was saved.
    it 'rolls back the earlier bill write when a later bill fails' do
      cook_2 = create(:resident, community: community, unit: unit)

      update_bills(
        meal_id: meal.id,
        bills: [
          { resident_id: cook.id, amount: '30.00', no_cost: false },
          { resident_id: cook_2.id, amount: '-5.00', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:bad_request)
      expect(bill.reload.amount).to eq(BigDecimal('0'))
      expect(meal.bills.where(resident: cook_2)).not_to exist
    end
  end

  describe 'malformed amount' do
    it 'returns 400 for non-numeric strings' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: 'abc', no_cost: false }]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
    end

    it 'does not modify the bill' do
      bill.update!(amount: BigDecimal('25'))

      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: 'not-a-number', no_cost: false }]
      )

      bill.reload
      expect(bill.amount).to eq(BigDecimal('25'))
    end
  end

  describe 'authentication' do
    it 'returns 401 without a token' do
      patch "/api/v1/meals/#{meal.id}/bills", params: {
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '50.00', no_cost: false }]
      }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['message']).to include('not authenticated')
    end

    it 'returns 401 with an invalid token' do
      update_bills(
        meal_id: meal.id,
        bills: [{ resident_id: cook.id, amount: '50.00', no_cost: false }],
        token: 'bogus-token-that-does-not-exist'
      )

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'third-cook warnings' do
    let(:rotation) { create(:rotation, community: community) }
    let(:future_meal) { create(:meal, community: community, date: 1.week.from_now, rotation: rotation) }
    let(:other_meal) { create(:meal, community: community, date: 2.weeks.from_now, rotation: rotation) }

    let(:cook_1) { create(:resident, community: community, unit: unit) }
    let(:cook_2) { create(:resident, community: community, unit: unit) }
    let(:cook_3) { create(:resident, community: community, unit: unit) }
    let(:cook_4) { create(:resident, community: community, unit: unit) }

    before do
      # future_meal starts with 2 cooks
      create(:bill, meal: future_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: future_meal, resident: cook_2, community: community, amount: BigDecimal('0'))
      # other_meal in the rotation has < 2 cooks (only 1)
      create(:bill, meal: other_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
    end

    it 'warns when adding a 3rd cook' do
      update_bills(
        meal_id: future_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Warning')
      expect(response.parsed_body['message']).to include('added')
      expect(response.parsed_body['type']).to eq('warning')
      # Bills are still saved despite the warning
      expect(future_meal.bills.count).to eq(3)
    end

    it 'includes the persisted bills alongside the warning — the write happened' do
      update_bills(
        meal_id: future_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['type']).to eq('warning')
      expect(response.parsed_body['bills']).to contain_exactly(
        { 'resident_id' => cook_1.id, 'amount' => '10.0', 'no_cost' => false },
        { 'resident_id' => cook_2.id, 'amount' => '10.0', 'no_cost' => false },
        { 'resident_id' => cook_3.id, 'amount' => '0.0', 'no_cost' => false }
      )
    end

    it 'warns when switching a 3rd cook' do
      # Add a 3rd cook first
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      update_bills(
        meal_id: future_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_4.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Warning')
      expect(response.parsed_body['message']).to include('switched')
      expect(response.parsed_body['type']).to eq('warning')
      # Cook was switched despite the warning
      expect(future_meal.bills.find_by(resident: cook_4)).to be_present
    end

    it 'does not warn when only updating cost for existing 3rd cook' do
      # Add a 3rd cook first
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      update_bills(
        meal_id: future_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '25.00', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
      expect(response.parsed_body).not_to have_key('type')
      cook_3_bill = future_meal.bills.find_by(resident: cook_3)
      cook_3_bill.reload
      expect(cook_3_bill.amount).to eq(BigDecimal('25'))
    end

    it 'does not warn when all rotation meals have 2+ cooks' do
      # Give other_meal a 2nd cook so rotation is fully staffed
      create(:bill, meal: other_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      update_bills(
        meal_id: future_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end

    it 'does not warn for future meal with no rotation' do
      no_rotation_meal = create(:meal, community: community, date: 3.weeks.from_now)
      create(:bill, meal: no_rotation_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: no_rotation_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      update_bills(
        meal_id: no_rotation_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end

    it 'does not warn for past meals' do
      past_meal = create(:meal, community: community, date: 1.week.ago, rotation: rotation)
      create(:bill, meal: past_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: past_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      update_bills(
        meal_id: past_meal.id,
        bills: [
          { resident_id: cook_1.id, amount: '10.00', no_cost: false },
          { resident_id: cook_2.id, amount: '10.00', no_cost: false },
          { resident_id: cook_3.id, amount: '0', no_cost: false }
        ]
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end
  end

  describe 'meal not found' do
    it 'returns 404 for a nonexistent meal' do
      update_bills(
        meal_id: 999_999,
        bills: [{ resident_id: cook.id, amount: '50.00', no_cost: false }]
      )

      expect(response).to have_http_status(:not_found)
    end
  end
end
