# frozen_string_literal: true

require 'rails_helper'

# Cancelling a dinner from the meal page, and restoring it (ADR 0011 rule
# 11): PATCH /api/v1/meals/:meal_id/cancelled. Anyone who can sign people
# up can do it. A cancelled dinner keeps its sign-ups and charges nobody,
# and its sign-ups, guests and costs are frozen until it is restored.
RSpec.describe 'Cancelling a dinner through the API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, name: 'Ann Eater') }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cid Cook') }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  def cancelled(value, of: meal)
    patch "/api/v1/meals/#{of.id}/cancelled", params: { token: token, cancelled: value }
  end

  def message
    response.parsed_body['message']
  end

  it 'cancels a dinner and keeps its sign-ups, then restores it as it was' do
    create(:meal_resident, meal: meal, resident: resident, community: community)
    meal.update!(closed: true)

    cancelled(true)
    expect(response).to have_http_status(:ok)
    expect(message).to eq('Dinner cancelled.')
    expect(meal.reload.cancelled_at).to be_present
    expect(meal.meal_residents.count).to eq(1)

    cancelled(false)
    expect(response).to have_http_status(:ok)
    expect(message).to eq('Dinner restored.')
    expect(meal.reload).to have_attributes(cancelled_at: nil, closed: true)
    expect(meal.meal_residents.count).to eq(1)
  end

  # A second tap, or a retry after an answer that was lost, keeps the
  # first time: the dinner is cancelled already.
  it 'keeps the first time when the dinner is cancelled again' do
    cancelled(true)
    first = meal.reload.cancelled_at

    cancelled(true)

    expect(response).to have_http_status(:ok)
    expect(meal.reload.cancelled_at).to eq(first)
  end

  it 'refuses to cancel a dinner a cook spent money on, and says why' do
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('12.50'))

    cancelled(true)

    expect(response).to have_http_status(:bad_request)
    expect(message).to eq("A cook spent money on this dinner, so it can't be cancelled.")
    expect(meal.reload.cancelled_at).to be_nil
  end

  it 'cancels a dinner whose cook has not entered a cost, or marked No cost' do
    create(:bill, meal: meal, resident: cook, community: community, amount: 0)
    create(:bill, meal: meal, resident: resident, community: community, amount: 0, no_cost: true)

    cancelled(true)

    expect(response).to have_http_status(:ok)
  end

  it 'refuses a missing or unclear answer with a sentence' do
    patch "/api/v1/meals/#{meal.id}/cancelled", params: { token: token }
    expect(response).to have_http_status(:bad_request)

    cancelled('maybe')
    expect(response).to have_http_status(:bad_request)
    expect(message).to eq('Cancelled must be true or false')
    expect(meal.reload.cancelled_at).to be_nil
  end

  it 'refuses both on a settled dinner' do
    meal.update!(date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: resident, community: community)
    settle!

    cancelled(true)

    expect(response).to have_http_status(:bad_request)
    expect(meal.reload.cancelled_at).to be_nil
  end

  # The settled check runs before the value is read, so a settled dinner
  # gets the settled words whatever was sent.
  it 'answers a settled dinner with the settled words before it reads the value' do
    meal.update!(date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    create(:meal_resident, meal: meal, resident: resident, community: community)
    settle!

    cancelled('maybe')
    expect(response).to have_http_status(:bad_request)
    expect(message).to eq('Change not permitted. Meal has already been reconciled.')

    patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: 'maybe' }
    expect(response).to have_http_status(:bad_request)
    expect(message).to eq('Change not permitted. Meal has already been reconciled.')
  end

  describe 'while the dinner is cancelled' do
    before do
      create(:meal_resident, meal: meal, resident: cook, community: community)
      cancelled(true)
    end

    it 'refuses a sign-up, a guest, a cost, and opening or closing it' do
      post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: false,
                                                                          vegetarian: false }
      expect(response).to have_http_status(:bad_request)
      expect(message).to eq('This dinner is cancelled. Restore it before changing it.')

      delete "/api/v1/meals/#{meal.id}/residents/#{cook.id}", params: { token: token }
      expect(response).to have_http_status(:bad_request)

      post "/api/v1/meals/#{meal.id}/residents/#{cook.id}/guests",
           params: { token: token, vegetarian: false, multiplier: 2 },
           headers: { 'Idempotency-Key' => SecureRandom.uuid }
      expect(response).to have_http_status(:bad_request)

      edits = [{ op: 'add', resident_id: cook.id, to: { amount: '0.00', no_cost: true } }]
      patch "/api/v1/meals/#{meal.id}/bills", params: { edits: edits, token: token },
                                              headers: BillEdits.key_header, as: :json
      expect(response).to have_http_status(:bad_request)
      expect(message).to eq('This dinner is cancelled. Restore it before changing it.')

      patch "/api/v1/meals/#{meal.id}/closed", params: { token: token, closed: true }
      expect(response).to have_http_status(:bad_request)
      expect(message).to eq('This dinner is cancelled. Restore it before changing it.')

      expect(meal.reload).to have_attributes(closed: false)
      expect(meal.meal_residents.pluck(:resident_id)).to eq([cook.id])
      expect(meal.guests).to be_empty
      expect(meal.bills).to be_empty
    end

    it 'takes a new description' do
      patch "/api/v1/meals/#{meal.id}/description", params: { token: token, description: 'Cook is sick' }

      expect(response).to have_http_status(:ok)
      expect(meal.reload.description).to eq('Cook is sick')
    end

    it 'tells the page, the calendar and the history' do
      get "/api/v1/meals/#{meal.id}/cooks", params: { token: token }
      expect(response.parsed_body['cancelled']).to be(true)

      get "/api/v1/communities/#{community.id}/calendar/#{meal.date.iso8601}", params: { token: token }
      chip = response.parsed_body.fetch('meals').find { |event| event['url'] == "/meals/#{meal.id}/edit" }
      expect(chip['title']).to eq("Dinner\nCancelled")

      get "/api/v1/meals/#{meal.id}/history", params: { token: token }
      expect(response.parsed_body['items'].pluck('description')).to include('Dinner cancelled')
    end
  end

  # A dinner closed before it was cancelled refuses a new sign-up for two
  # reasons. The answer gives both, each on its own line.
  it 'gives every reason a sign-up is refused, one per line' do
    meal.update!(closed: true)
    cancelled(true)

    post "/api/v1/meals/#{meal.id}/residents/#{resident.id}", params: { token: token, late: false,
                                                                        vegetarian: false }

    expect(response).to have_http_status(:bad_request)
    expect(message).to eq("This dinner is cancelled. Restore it before changing it.\nMeal has been closed.")
    expect(meal.meal_residents.reload).to be_empty
  end
end
