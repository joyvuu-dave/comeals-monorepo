# frozen_string_literal: true

require 'rails_helper'

# Where a correction to a settled dinner shows (ADR 0011 rule 6): on the
# dinner's page, with the cost after the correction; on the settlement
# preview and the settlement that carries it; and on each person's
# statement, under that settlement. The words are CorrectionWords' and
# the direction words BalanceDisplayHelper's.
RSpec.describe 'Admin pages for a corrected dinner' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Unit A') }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true, email: 'books@example.com') }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook One') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }

  let!(:meal) do
    create(:meal, community: community, date: latest - 5).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
      settle!(cutoff: latest - 5)
    end
  end
  let!(:correction) do
    MealCorrecting.save!(meal.reload, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end
  end

  before do
    host! 'admin.example.com'
    sign_in admin
  end

  def page
    response.parsed_body
  end

  def panel(title)
    page.css('.panel').find { |panel| panel.at_css('h3').text.start_with?(title) }
  end

  def rows(container)
    container.css('tbody tr').map { |row| row.css('td').map { |cell| cell.text.squish } }
  end

  def expect_the_correction(container)
    expect(container.text.squish).to include("Made #{correction.created_at.strftime('%b %-d, %Y')} by " \
                                             'books@example.com. Reason: Typed $30 for $20')
      .and include("Changed Cook One's cost from $30.00 to $20.00.")
    expect(rows(container)).to eq([['Cook One', 'charged $10.00'], ['Eater One', 'credited $10.00']])
  end

  it 'shows the correction on the dinner\'s page, and the cost after it' do
    get "/meals/#{meal.id}"

    corrections = panel('Corrections (1)')
    expect(corrections.at_css('h4').text.squish).to eq('Waits for the next settlement')
    expect_the_correction(corrections)
    expect(page.at_css('.row-total_cost td').text).to eq('$20.00')
    # What it was settled at stays in the line items.
    expect(rows(panel('Settlement line items'))).to include(['Cook One', 'Cooked', '', 'credited $30.00'])
  end

  it 'says when a correction moves no money' do
    MealCorrecting.save!(meal.reload, by: admin, reason: 'A helper spent nothing') do |edits|
      edits.cost(eater, amount: BigDecimal('0'), no_cost: true)
    end

    get "/meals/#{meal.id}"

    expect(panel('Corrections (2)').text.squish)
      .to include('Added Eater One as a cook (No cost).').and include('Nobody owes or is owed a different amount.')
  end

  # The lines are saved in the order of the people's ids. The table lists
  # them by name, and links each name to that person's page. A resident
  # who is in no line is made first, so no line has its resident's id.
  it 'lists a correction\'s edits, and its people by name, each linked to their page' do
    create(:resident, community: community, unit: unit, name: 'Not In It')
    able = create(:resident, community: community, unit: unit, name: 'Able Eater')
    MealCorrecting.save!(meal.reload, by: admin, reason: 'Able Eater ate too') { |edits| edits.add_eater(able) }

    get "/meals/#{meal.id}"

    details = panel('Corrections (2)').css('.meal_correction_details').last
    expect(details.css('ul > li').map(&:text)).to eq(['Signed up Able Eater (Adult).'])
    expect(details.css('thead th').map(&:text)).to eq(%w[Resident Change])
    # $20 after the first correction: the eater was charged all of it, and
    # now each of the two is charged $10.
    expect(rows(details)).to eq([['Able Eater', 'charged $10.00'], ['Eater One', 'credited $10.00']])
    expect(details.css('tbody a').pluck('href')).to eq(["/residents/#{able.id}", "/residents/#{eater.id}"])
  end

  it 'says which settlement carries it once one does' do
    second = settle!(cutoff: latest)

    get "/meals/#{meal.id}"

    link = panel('Corrections (1)').at_css('h4 a')
    expect(link.text).to eq("the settlement of #{second.date.strftime('%b %-d, %Y')}")
    expect(link['href']).to eq("/reconciliations/#{second.id}")
  end

  it 'shows the correction on the settlement preview, which may carry only corrections' do
    get "/reconciliations/preview?#{{ reconciliation: { end_date: latest.iso8601 } }.to_query}"

    corrections = panel('Corrections this settlement will carry (1)')
    expect(corrections.at_css('h4 a').text).to eq("Correction to the #{meal.date.iso8601} dinner")
    expect_the_correction(corrections)
    expect(rows(panel("Each person's amount")))
      .to contain_exactly(['Cook One', 'Unit A', 'owes $10.00'], ['Eater One', 'Unit A', 'is owed $10.00'])
    expect(page.at_css("form[action='/reconciliations'] button[type=submit]").text).to eq('Create Reconciliation')
  end

  it 'shows the correction on the settlement that carries it' do
    second = settle!(cutoff: latest)

    get "/reconciliations/#{second.id}"

    corrections = panel('Corrections Carried (1)')
    expect(corrections.at_css('h4 a')['href']).to eq("/meals/#{meal.id}")
    expect_the_correction(corrections)
  end

  it 'shows each person\'s change on their statement, under the settlement that carries it' do
    second = settle!(cutoff: latest)

    get "/residents/#{eater.id}"

    statement = panel('Settlement statement')
    expect(statement.text.squish).to include('settled: is owed $10.00')
    expect(rows(statement)).to include(["To the #{meal.date.iso8601} dinner", 'Typed $30 for $20',
                                        'credited $10.00'])
    expect(statement.css("a[href='/reconciliations/#{second.id}']")).not_to be_empty
  end

  it 'refuses to delete the admin who made a correction, and says why' do
    other = create(:admin_user, community: community, superuser: true)
    sign_in other

    expect { delete "/admin_users/#{admin.id}" }.not_to change(AdminUser, :count)
    follow_redirect!
    expect(response.body).to include('meal corrections')
  end
end
