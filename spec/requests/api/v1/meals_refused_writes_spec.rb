# frozen_string_literal: true

require 'rails_helper'

# What the meal endpoints answer when the model, or the database under it,
# refuses a write. Each is a 400 that carries the reason, never a 500. The
# refusals are staged: today no validation on these rows can fail through
# the API's own checks, and the database exceptions below only happen in a
# race the checks cannot see (a cook deleted between the lookup and the
# insert). The rescue clauses exist for exactly those cases, so the
# examples raise them on purpose and pin what the client gets.
RSpec.describe 'meal writes that are refused' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.tomorrow) }

  describe 'a meal that no longer passes validation' do
    # A closed meal whose max fell below its headcount, the way a hand edit
    # in psql could leave it.
    before do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.update!(closed: true)
      meal.update_columns(max: 0)
    end

    it 'refuses a new description and says why' do
      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Soup' }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include("Max can't be less than current number of attendees.")
      expect(meal.reload.description).not_to eq('Soup')
    end

    it 'refuses to reopen and says why' do
      patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: false }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include("Max can't be less than current number of attendees.")
      expect(meal.reload.closed).to be(true)
    end
  end

  describe 'an attendance row the model refuses to update' do
    it 'answers with the model\'s message' do
      attendance = create(:meal_resident, meal: meal, resident: resident, community: community)
      allow(MealResident).to receive(:find_by).and_return(attendance)
      allow(attendance).to receive(:update) do
        attendance.errors.add(:base, 'Attendance is frozen.')
        false
      end

      patch "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: true }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Attendance is frozen.')
    end
  end

  describe 'a bills write the database refuses' do
    let(:cook) { create(:resident, community: community, unit: unit) }

    # The controller reaches the bills through the meal it loaded, so the
    # meal's bills relation is where the refusal is staged.
    def stage(error)
      bills = Bill.where(meal_id: meal.id)
      allow(bills).to receive(:find_or_initialize_by).and_raise(error)
      allow(meal).to receive(:bills).and_return(bills)
      loaded = Meal.all
      allow(loaded).to receive(:find_by).and_return(meal)
      allow(Meal).to receive(:includes).and_return(loaded)
    end

    def submit
      patch "/api/v1/meals/#{meal.id}/bills",
            params: { token: token, bills: [{ resident_id: cook.id, amount: '12.00', no_cost: false }] }
    end

    it 'answers a validation failure with the validation message' do
      invalid = Bill.new
      invalid.errors.add(:amount, 'must be whole cents')
      stage(ActiveRecord::RecordInvalid.new(invalid))

      submit

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Validation failed: Amount must be whole cents')
    end

    it 'answers a refused destroy with the record\'s message' do
      refused = Bill.new
      refused.errors.add(:base, 'This bill belongs to a settled meal.')
      stage(ActiveRecord::RecordNotDestroyed.new('Failed to destroy', refused))

      submit

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('This bill belongs to a settled meal.')
    end

    it 'answers a foreign key violation as a bad cook assignment' do
      stage(ActiveRecord::InvalidForeignKey.new('PG::ForeignKeyViolation'))

      submit

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Invalid cook assignment.')
    end

    it 'answers a numeric overflow as a bad amount' do
      stage(ActiveRecord::RangeError.new('PG::NumericValueOutOfRange'))

      submit

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Invalid amount. Amounts are whole cents, 0 to 9999.99.')
    end
  end
end
