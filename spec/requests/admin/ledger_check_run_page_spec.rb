# frozen_string_literal: true

require 'rails_helper'

# The run page of a ledger check that found something. LedgerVerification
# runs two checks, and the same three keys (resident_id, stored, source)
# mean a different thing in each: the balance rebuilt from bills and
# sign-ups, the sum of one person's meal lines, or, with no resident, the
# sum of all of a settlement's meal lines. The page once showed all three
# under "Stored at settlement" and "Source data says", so a settlement
# whose lines did not add up to zero looked like a missing balance for an
# unknown person.
RSpec.describe 'Admin ledger check run page' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Rosa Lister') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Omar Brandt') }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community)
  end

  # Settled data is immutable by design, so a finding can only be set up
  # the way a hand edit would make one.
  def behind_the_guards
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
      yield
    end
  end

  # The cook is owed $40 and the eater owes $40.
  def settle
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!(cutoff: Date.yesterday)
  end

  def findings_table
    panel = response.parsed_body.css('.panel').find { |node| node.at_css('h3')&.text == 'What disagreed' }
    panel.css('tbody tr').map { |row| row.css('td').map { |cell| cell.text.squish } }
  end

  def run_page(details)
    run = create(:ledger_check_run, mismatch_count: details.size, details: details)
    get "/ledger_check_runs/#{run.id}"
    expect(response).to have_http_status(:ok)
  end

  it 'says which check found each difference, whose balance it is, and which way it goes, without a sign' do
    reconciliation = settle
    behind_the_guards do
      # The cook's credit drops by 50 cents, so the lines add up to 50
      # cents less than zero. The cook's balance drops with it, so only
      # the recompute check sees the cook. The eater's balance moves
      # alone, so both checks see the eater.
      MealCharge.where(meal_id: reconciliation.meals.select(:id), resident_id: cook.id, kind: 'credit')
                .update_all(amount: BigDecimal('79.5'))
      balances = ReconciliationBalance.where(reconciliation_id: reconciliation.id)
      balances.where(resident_id: cook.id).update_all(amount: BigDecimal('39.5'))
      balances.where(resident_id: eater.id).update_all(amount: BigDecimal('-39.9'))
    end
    suppress(LedgerVerification::MismatchError) { LedgerVerification.call }

    get "/ledger_check_runs/#{LedgerCheckRun.recent.first.id}"

    settled = "##{reconciliation.id} (#{reconciliation.date.iso8601})"
    expect(findings_table).to eq(
      [
        [settled, 'Balance rebuilt from bills and sign-ups', 'Rosa Lister', 'is owed $39.50', 'is owed $40.00'],
        [settled, 'Balance rebuilt from bills and sign-ups', 'Omar Brandt', 'owes $39.90', 'owes $40.00'],
        [settled, 'Sum of their meal lines', 'Omar Brandt', 'owes $39.90', 'owes $40.00'],
        [settled, 'Sum of all meal lines', 'Whole settlement', '',
         'Charges are $0.50 more than credits. They must be equal.']
      ]
    )
    expect(response.parsed_body.css('td.col-resident a').pluck('href'))
      .to eq(["/residents/#{cook.id}", "/residents/#{eater.id}", "/residents/#{eater.id}"])
  end

  it 'shows every digit a difference has, so one smaller than a cent is not shown as $0.00' do
    run_page([{ 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'line_items',
                'differences' => [{ 'resident_id' => nil, 'stored' => nil, 'source' => '0.00000001' },
                                  { 'resident_id' => cook.id, 'stored' => '12.38', 'source' => '12.39999999' }] }])

    expect(findings_table.map(&:last))
      .to eq(['Credits are $0.00000001 more than charges. They must be equal.', 'is owed $12.39999999'])
  end

  # A balance of zero is not stored, so either side can be missing. A
  # missing side is not a zero balance on the screen: it is a row that
  # vanished, or one that should not be there.
  it 'says which side has no row, in the words of the check that found it' do
    run_page([{ 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'recompute',
                'differences' => [{ 'resident_id' => cook.id, 'stored' => nil, 'source' => '40.0' },
                                  { 'resident_id' => eater.id, 'stored' => '-40.0', 'source' => nil }] },
              { 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'line_items',
                'differences' => [{ 'resident_id' => cook.id, 'stored' => nil, 'source' => '40.0' },
                                  { 'resident_id' => eater.id, 'stored' => '-40.0', 'source' => nil }] }])

    expect(findings_table.map { |row| row.last(2) }).to eq(
      [['No balance stored', 'is owed $40.00'], ['owes $40.00', 'No balance'],
       ['No balance stored', 'is owed $40.00'], ['owes $40.00', 'No meal lines']]
    )
  end

  # The first runs, from 2026-08-02, stored no check label: the recompute
  # check was the only one until the meal lines were added the same day.
  it 'reads a finding from a run that named no check as the recompute check' do
    run_page([{ 'reconciliation_id' => 4, 'date' => '2026-07-01',
                'differences' => [{ 'resident_id' => cook.id, 'stored' => '40.0', 'source' => '39.0' }] }])

    expect(findings_table)
      .to eq([['#4 (2026-07-01)', 'Balance rebuilt from bills and sign-ups', 'Rosa Lister', 'is owed $40.00',
               'is owed $39.00']])
  end

  # A label this page does not know comes from a check added later. It
  # is shown as stored, so the page still says what was found.
  it 'shows a check it does not know by its stored label' do
    run_page([{ 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'cents_rounding',
                'differences' => [{ 'resident_id' => cook.id, 'stored' => '40.0', 'source' => nil }] }])

    expect(findings_table).to eq([['#4 (2026-09-30)', 'cents_rounding', 'Rosa Lister', 'is owed $40.00', 'No row']])
  end

  # A settled resident cannot be deleted, but a run is a record of what
  # was true, and it names residents by id. The page still renders.
  it 'names a resident it cannot find by id' do
    run_page([{ 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'recompute',
                'differences' => [{ 'resident_id' => 999_999, 'stored' => '40.0', 'source' => '39.0' }] }])

    expect(findings_table.first[2]).to eq('Resident #999999 (not found)')
  end

  it 'reads every resident a run names in one query' do
    run = create(:ledger_check_run, mismatch_count: 2, details: [
                   { 'reconciliation_id' => 4, 'date' => '2026-09-30', 'check' => 'recompute',
                     'differences' => [{ 'resident_id' => cook.id, 'stored' => '1.0', 'source' => '2.0' }] },
                   { 'reconciliation_id' => 5, 'date' => '2026-10-07', 'check' => 'recompute',
                     'differences' => [{ 'resident_id' => eater.id, 'stored' => '1.0', 'source' => '2.0' }] }
                 ])
    statements = []
    recorder = ->(*, event) { statements << event[:sql] if event[:sql].include?('FROM "residents"') }

    ActiveSupport::Notifications.subscribed(recorder, 'sql.active_record') { get "/ledger_check_runs/#{run.id}" }

    expect(statements.size).to eq(1)
  end

  it 'explains both checks where it explains what "mismatched" means' do
    get '/ledger_check_runs'

    sidebar = response.parsed_body.at_css('#what-this-page-shows_sidebar_section').text.squish
    expect(sidebar).to include('Mismatched — a stored balance no longer agrees with the balance rebuilt from ' \
                               "bills and sign-ups, or with the sum of that person's meal lines, or a " \
                               "settlement's meal lines no longer add up to $0.00.")
  end
end
