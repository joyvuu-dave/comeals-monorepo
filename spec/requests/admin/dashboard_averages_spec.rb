# frozen_string_literal: true

require 'rails_helper'

# The dashboard's "Averages" panel, as an admin reads it. The averages
# read only meals whose costs are final (Community#averaged_meals), and
# the panel says how many meals that is and how many were left out and
# why, so a missing receipt stays in view.
RSpec.describe 'Admin dashboard averages' do
  let(:community) { create(:community, cap: nil) }
  let(:unit) { create(:unit, community: community) }
  let(:admin_user) { create(:admin_user, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:diner) { create(:resident, community: community, unit: unit) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def meal_on(date, amounts: [], eaters: [])
    meal = create(:meal, community: community, date: date)
    amounts.each do |amount|
      create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit),
                    community: community, amount: BigDecimal(amount))
    end
    eaters.each { |eater| create(:meal_resident, meal: meal, resident: eater, community: community) }
  end

  def averages_panel
    panel = response.parsed_body.css('.panel').find { |node| node.at_css('h3')&.text == 'Averages' }
    panel.css('li').map { |item| item.text.squish }
  end

  it 'shows the averages of the meals whose costs are final, and why the others were left out' do
    meal_on(community.today - 1, amounts: %w[16.25], eaters: [cook, diner])
    meal_on(community.today - 2, eaters: [diner])
    meal_on(community.today - 3, amounts: %w[0], eaters: [diner])
    meal_on(community.today - 4, amounts: %w[0], eaters: [diner])
    meal_on(community.today, amounts: %w[0], eaters: [diner])
    meal_on(community.today + 7, eaters: [diner])
    create(:meal, community: community, date: community.today + 14)

    get '/'

    # 2 * (16.25 / 4) is exactly 8.125; two people ate at the one meal.
    expect(averages_panel).to eq(
      ['Cost per adult: $8.13/adult', 'Attendees per meal: 2.0',
       'Meals counted: 1 (days that are over, not settled yet)',
       "Left out: 2 meals waiting for a cook's cost, 1 meal with no cook"]
    )
  end

  it 'names a meal only people who eat free ate' do
    child = create(:resident, community: community, unit: unit, multiplier: 0)
    meal_on(community.today - 1, amounts: %w[10], eaters: [child])

    get '/'

    expect(averages_panel.last(2))
      .to eq(['Meals counted: 0 (days that are over, not settled yet)', 'Left out: 1 meal where only free eaters ate'])
  end

  it 'says when nothing was left out' do
    meal_on(community.today - 1, amounts: %w[16], eaters: [cook, diner])

    get '/'

    expect(averages_panel.last).to eq('Left out: none')
  end
end
