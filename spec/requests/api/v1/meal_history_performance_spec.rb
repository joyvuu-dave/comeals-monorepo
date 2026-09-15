# frozen_string_literal: true

require 'rails_helper'

# The history modal describes every audit row of a meal. A row names its
# record and its resident by id, so the describer has to look them up;
# it must do that once for the whole list, not once per row (#84: a
# meal with a long history ran a few hundred queries for one modal).
RSpec.describe 'Meal history endpoint performance' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community) }

  # Every kind of row the describer reads: attendance rows that were
  # updated (the record is looked up), then some deleted (the create
  # audit is looked up instead), bills the same way, guests, and meal
  # changes. Twelve people, so a per-row lookup shows as a count that
  # grows with the list.
  before do
    people = Array.new(12) { create(:resident, community: community, unit: unit) }
    people.each do |person|
      attendance = create(:meal_resident, meal: meal, resident: person, community: community, late: false)
      attendance.update!(late: true)
      attendance.destroy! if person.id.odd?
    end
    people.first(4).each do |person|
      bill = create(:bill, meal: meal, resident: person, community: community, amount: BigDecimal('30'))
      bill.update!(amount: BigDecimal('40'))
    end
    Bill.where(meal: meal).first.destroy!
    people.first(3).each { |person| create(:guest, meal: meal, resident: person, vegetarian: false) }
    meal.guests.first.destroy!
    meal.update!(description: 'Pasta')
  end

  # The budget: token auth (3: the key, the resident, the community),
  # the meal with its bills, attendance rows and guests (4), the meal's
  # audits and its rows' audits (2), the resident names (1), and the
  # describer's lookups (5): the bills and attendance rows the update
  # rows point at, the create audits of the ones that are gone (one
  # query per table), and every resident the rows name.
  it 'describes the whole history in a bounded number of queries' do
    token
    get "/api/v1/meals/#{meal.id}/history", params: { token: token }

    query_count = count_queries do
      get "/api/v1/meals/#{meal.id}/history", params: { token: token }
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['items'].size).to be > 40
    expect(query_count).to be <= 15
  end

  it 'names every person the same way the per-row describer did' do
    get "/api/v1/meals/#{meal.id}/history", params: { token: token }

    descriptions = response.parsed_body['items'].pluck('description')
    expect(descriptions).not_to include(a_string_matching(/unknown/))
    expect(descriptions).to include(a_string_matching(/ removed\z/), a_string_matching(/ marked late\z/),
                                    a_string_matching(/\ABill for .* changed from \$30\.00 to \$40\.00\z/),
                                    a_string_matching(/ removed as cook\z/), a_string_matching(/\AOmnivore guest of /),
                                    'Menu description updated')
  end
end
