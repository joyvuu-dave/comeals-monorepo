# frozen_string_literal: true

require 'rails_helper'

# The settlement statement: the admin pages that show what a settled number is
# made of, line by line, from meal_charges. The resident page answers "what am
# I being charged for", the meal page answers "who was charged for this meal".
RSpec.describe 'Admin settlement statement' do
  let(:community) { create(:community, cap: BigDecimal('4.50')) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  # $16 across four units of multiplier: $4 a unit, each adult is charged $8,
  # the cook is credited the whole $16. Same arithmetic as meal_charge_spec.
  def settle_plain_meal
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
    create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)

    Reconciliation.create!(community: community, end_date: Date.yesterday)
  end

  describe 'the resident page' do
    it 'shows the statement: one section per settlement, one line per charge' do
      reconciliation = settle_plain_meal

      get "/residents/#{eater.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Settlement statement')
      expect(response.body).to include(reconciliation.date_range_description)
      # The eater's settled balance and their one line, in direction words —
      # never a signed number (BalanceDisplayHelper).
      expect(response.body).to include('settled:')
      expect(response.body).to include('owes $8.00')
      expect(response.body).to include('Attended')
      expect(response.body).to include('charged $8.00')
      expect(response.body).not_to include('-$8.00')
      # No capped cook in this section, so the column that explains capping
      # is absent rather than blank.
      expect(response.body).not_to include('Cook spent')
    end

    # Regression: the heading used to say "#{date} to #{end_date}" — the day
    # the settlement ran "to" the sweep cutoff, which read backwards
    # ("2026-08-10 to 2026-06-15"). The heading is the swept meals' own range.
    it 'labels each section with the dates of the meals the settlement swept' do
      [Date.new(2026, 6, 1), Date.new(2026, 6, 15)].each do |date|
        meal = create(:meal, community: community, date: date)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
        create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      end
      reconciliation = Reconciliation.create!(community: community, end_date: Date.new(2026, 6, 15))

      get "/residents/#{eater.id}"

      expect(response.body).to include('Jun 1–15, 2026')
      expect(response.body).not_to include("#{reconciliation.date} to #{reconciliation.end_date}")
    end

    it 'shows the cook a credit line' do
      settle_plain_meal

      get "/residents/#{cook.id}"

      expect(response.body).to include('Cooked')
      expect(response.body).to include('credited $16.00')
      # The cook also ate, so their settled balance is $16 minus their $8 share.
      expect(response.body).to include('is owed $8.00')
    end

    it 'says when a settlement has no recorded line items, instead of showing zero charges' do
      # Reconciliations settled before 2026-08-02 have no meal_charges rows,
      # deliberately not backfilled. Line items are immutable through every
      # normal path, so this recreates that state the way the repair runbook
      # does: delete_all (no callbacks) under the repair setting (no trigger).
      reconciliation = settle_plain_meal
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      MealCharge.for_reconciliation(reconciliation).delete_all

      get "/residents/#{eater.id}"

      expect(response.body).to include('No line items were recorded for this settlement.')
    end

    it 'shows what a subsidized cook actually spent next to what they were credited' do
      # 4 units of multiplier * 4.50 = 18.00 allowed, against 60.00 spent.
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: meal, resident: cook, community: community, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      Reconciliation.create!(community: community, end_date: Date.yesterday)

      get "/residents/#{cook.id}"

      expect(response.body).to include('Cook spent')
      expect(response.body).to include('$60.00')
      expect(response.body).to include('$18.00')
    end

    it 'shows nothing but a plain sentence for a resident with no settled history' do
      get "/residents/#{eater.id}"

      expect(response.body).to include('No settled balances yet.')
    end
  end

  describe 'the meal page' do
    it 'shows the line items once the meal is reconciled' do
      reconciliation = settle_plain_meal
      meal = reconciliation.meals.first

      get "/meals/#{meal.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Settlement line items')
      expect(response.body).to include('Cooked')
      expect(response.body).to include('Attended')
    end

    it 'shows no line-items panel on an open meal' do
      meal = create(:meal, community: community)

      get "/meals/#{meal.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Settlement line items')
    end
  end
end
