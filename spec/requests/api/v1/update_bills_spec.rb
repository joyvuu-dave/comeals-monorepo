# frozen_string_literal: true

require 'rails_helper'

# A bills save sends edits: each names one cook, and a change or a remove
# carries the bill the page saw for that cook (#135, ADR 0009). The rules
# for the body, and what each edit does to the stored bill, are pinned
# one by one in spec/services/bills_payload_spec.rb. This file proves the
# endpoint: the statuses, the answers, the lock, and that a refused save
# writes nothing.
RSpec.describe 'PATCH /api/v1/meals/:meal_id/bills' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Bob') }
  let!(:bill) { create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0')) }

  # The server's words for a write to a settled meal, from the contract
  # file the Vitest tests read too (docs/adr/0001-typescript-at-the-api-boundary.md).
  let(:reconciled_rejection) do
    JSON.parse(Rails.root.join('tests/fixtures/api_contract.json').read)
        .fetch('messages').fetch('reconciled_rejection')
  end

  # JSON, as the page sends it, with a new Idempotency-Key. A
  # form-encoded body has its own examples, and the key its own file
  # (bills_idempotency_key_spec.rb).
  def save_edits(edits, meal_id: meal.id, token: self.token)
    patch "/api/v1/meals/#{meal_id}/bills", params: { edits: edits, token: token }, headers: BillEdits.key_header,
                                            as: :json
  end

  def values(amount, no_cost: false)
    { amount: amount, no_cost: no_cost }
  end

  def adding(resident, to)
    { op: 'add', resident_id: resident.id, to: to }
  end

  def changing(resident, from, to)
    { op: 'change', resident_id: resident.id, from: from, to: to }
  end

  def removing(resident, from)
    { op: 'remove', resident_id: resident.id, from: from }
  end

  # The cook's bill as the meal form shows it at the start.
  def seen
    values('0.0')
  end

  def new_cook(name = nil)
    create(:resident, community: community, unit: unit, **(name ? { name: name } : {}))
  end

  def bill_audits
    meal.associated_audits.where(auditable_type: 'Bill')
  end

  describe 'a change' do
    it 'writes the new amount and answers 200' do
      save_edits([changing(cook, seen, values('75.50'))])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
      bill.reload
      expect(bill.amount).to eq(BigDecimal('75.50'))
      expect(bill.no_cost).to be(false)
    end

    it 'answers with the bills as stored, so the client sees what the server kept' do
      save_edits([changing(cook, seen, values('75.50'))])

      expect(response).to have_http_status(:ok)
      # Rails encodes BigDecimal as a string and drops trailing zeros.
      expect(response.parsed_body['bills']).to contain_exactly(
        { 'resident_id' => cook.id, 'amount' => '75.5', 'no_cost' => false }
      )
    end

    it 'stores the amount as a BigDecimal, to the cent' do
      save_edits([changing(cook, seen, values('50.01'))])

      bill.reload
      expect(bill.amount).to be_a(BigDecimal)
      expect(bill.amount).to eq(BigDecimal('50.01'))
    end

    it 'writes several cooks in one save' do
      cook_2 = new_cook

      save_edits([changing(cook, seen, values('30.00')), adding(cook_2, values('20.00'))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(2)
      expect(meal.bills.find_by(resident: cook).amount).to eq(BigDecimal('30'))
      expect(meal.bills.find_by(resident: cook_2).amount).to eq(BigDecimal('20'))
    end

    it 'records the old and the new amount in the meal history' do
      bill.update!(amount: BigDecimal('5'))

      save_edits([changing(cook, values('5.0'), values('7.00'))])

      update = bill_audits.where(action: 'update').last
      expect(update.audited_changes['amount'].map { |amount| BigDecimal(amount.to_s) })
        .to eq([BigDecimal('5'), BigDecimal('7')])
    end
  end

  describe 'an add' do
    it 'makes a new cook with their bill' do
      added = new_cook

      save_edits([adding(added, values('25.00'))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(2)
      expect(meal.bills.find_by(resident: added).amount).to eq(BigDecimal('25'))
    end

    # A cook picked in a blank row, before a cost is typed.
    it 'makes a zero bill from a blank amount' do
      added = new_cook

      save_edits([adding(added, values(''))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.find_by(resident: added).amount).to eq(BigDecimal('0'))
    end
  end

  describe 'a remove' do
    it 'removes the bill and records the removal in the meal history' do
      departing = new_cook
      departing_bill = create(:bill, meal: meal, resident: departing, community: community, amount: BigDecimal('80'))

      save_edits([removing(departing, values('80.0'))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.pluck(:resident_id)).to contain_exactly(cook.id)
      destroy_audit = bill_audits.find_by(auditable_id: departing_bill.id, action: 'destroy')
      expect(destroy_audit).not_to be_nil
      expect(BigDecimal(destroy_audit.audited_changes['amount'].to_s)).to eq(BigDecimal('80'))
    end

    it 'removes every cook when every cook is removed' do
      second = new_cook
      create(:bill, meal: meal, resident: second, community: community, amount: BigDecimal('3'))

      save_edits([removing(cook, seen), removing(second, values('3.0'))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.count).to eq(0)
      expect(bill_audits.where(action: 'destroy').count).to eq(2)
    end

    # The save reads the meal's bills before it writes, and destroying a
    # bill does not take it out of that loaded list. The answer must read
    # the rows again, or it lists a cook who is gone.
    it 'leaves the removed cook out of the answer' do
      bill.update!(amount: BigDecimal('5'))
      carol = new_cook('Carol')
      create(:bill, meal: meal, resident: carol, community: community, amount: BigDecimal('8'))

      save_edits([removing(carol, values('8.0')), changing(cook, values('5.0'), values('6.00'))])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['bills']).to eq([{ 'resident_id' => cook.id, 'amount' => '6.0', 'no_cost' => false }])
    end
  end

  # The old format removed any cook a save left out (#135). Now a cook a
  # save does not name is never touched, not even rewritten with its own
  # values.
  describe 'a cook the save does not name' do
    it 'keeps their stored amount and no_cost, and their row is not written' do
      bill.update!(amount: BigDecimal('12.34'), no_cost: false)
      untouched_at = bill.reload.updated_at

      save_edits([adding(new_cook, values('5.00'))])

      expect(response).to have_http_status(:ok)
      bill.reload
      expect([bill.amount, bill.no_cost, bill.updated_at]).to eq([BigDecimal('12.34'), false, untouched_at])
    end

    it 'is in the answer with its stored values' do
      bill.update!(amount: BigDecimal('12.34'), no_cost: false)
      added = new_cook

      save_edits([adding(added, values('5.00'))])

      expect(response.parsed_body['bills']).to contain_exactly(
        { 'resident_id' => cook.id, 'amount' => '12.34', 'no_cost' => false },
        { 'resident_id' => added.id, 'amount' => '5.0', 'no_cost' => false }
      )
    end
  end

  describe 'no_cost bills' do
    # The page turns no-cost on by sending a blank amount with it.
    it 'sets the no_cost flag on the bill' do
      save_edits([changing(cook, seen, values('', no_cost: true))])

      expect(response).to have_http_status(:ok)
      bill.reload
      expect(bill.no_cost).to be(true)
      expect(bill.amount).to eq(BigDecimal('0'))
    end

    # The no_cost row carries money on purpose: the API keeps an amount
    # next to no_cost, so only leaving the row out keeps the total at 60.
    it 'leaves no_cost bills out of total_cost' do
      create(:meal_resident, meal: meal, resident: resident, community: community)
      paying_cook = new_cook

      save_edits([changing(cook, seen, values('15.00', no_cost: true)), adding(paying_cook, values('60.00'))])

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('15'))
      expect(MealCostSummary.for(meal.reload).total_cost).to eq(BigDecimal('60'))
    end

    # Issue #138. no_cost follows the rule of every true/false value the
    # API reads, with the same words. Rails would read "False" as true,
    # and the meal's cost would drop by the bill.
    it 'refuses no_cost "False", and writes nothing' do
      save_edits([changing(cook, seen, values('12.00', no_cost: 'False'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('No cost must be true or false')
      expect(bill.reload).to have_attributes(amount: BigDecimal('0'), no_cost: false)
    end

    # Issue #139: in the old format a no_cost of "" reached the NOT NULL
    # column as nil, a 500.
    it 'refuses no_cost "" with a 400, not a 500, and writes nothing' do
      save_edits([changing(cook, seen, values('12.00', no_cost: ''))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('No cost must be true or false')
      expect(bill.reload).to have_attributes(amount: BigDecimal('0'), no_cost: false)
    end

    it 'takes 1 and 0, as JSON numbers and as text, as true and false' do
      added = new_cook

      save_edits([changing(cook, values('0.0', no_cost: 0), values('', no_cost: 1)),
                  adding(added, values('4.50', no_cost: '0'))])

      expect(response).to have_http_status(:ok)
      expect(meal.bills.reload.to_h { |b| [b.resident_id, b.no_cost] }).to eq(cook.id => true, added.id => false)
    end
  end

  # One save from a page that has not loaded the meal again since another
  # save (two pages: spec/requests/api/v1/two_pages_bills_spec.rb).
  describe 'a save built on bills that changed after the page read them' do
    it 'answers 409 stale, names every cook that changed, and carries the bills as stored' do
      carol = new_cook('Carol')
      bill.update!(amount: BigDecimal('9'))

      save_edits([changing(cook, values('5.0'), values('7.00')), changing(carol, values('1.0'), values('2.00'))])

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to eq(
        'message' => 'Nothing was saved, because this meal changed after you loaded it: ' \
                     "Bob's cost changed and Carol is no longer a cook. " \
                     'Check the cooks and costs, then enter your change again.',
        'type' => 'stale',
        'bills' => [{ 'resident_id' => cook.id, 'amount' => '9.0', 'no_cost' => false }]
      )
    end

    it 'writes none of the edits, not even the ones that still match, and leaves no audit' do
      dan = new_cook
      create(:bill, meal: meal, resident: dan, community: community, amount: BigDecimal('4'))
      bill.update!(amount: BigDecimal('9'))
      audits = bill_audits.count

      save_edits([changing(dan, values('4.0'), values('6.00')), changing(cook, values('5.0'), values('7.00'))])

      expect(response).to have_http_status(:conflict)
      expect(meal.bills.reload.to_h { |b| [b.resident_id, b.amount] })
        .to eq(cook.id => BigDecimal('9'), dan.id => BigDecimal('4'))
      expect(bill_audits.count).to eq(audits)
    end

    it 'sends no live update' do
      bill.update!(amount: BigDecimal('9'))
      # The rows above pushed when they were written; only the save counts.
      token
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      save_edits([changing(cook, values('5.0'), values('7.00'))])

      expect(response).to have_http_status(:conflict)
      expect(Pusher).not_to have_received(:trigger)
    end
  end

  # The same save sent twice (a resend after no answer), or another page
  # that made the same change first.
  describe 'an edit the stored bills already show' do
    it 'answers 200 with the bills, and writes nothing' do
      bill.update!(amount: BigDecimal('7'))
      audits = bill_audits.count
      written_at = bill.reload.updated_at

      save_edits([changing(cook, values('5.0'), values('7.00')), removing(new_cook, values('3.0'))])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['bills']).to eq([{ 'resident_id' => cook.id, 'amount' => '7.0', 'no_cost' => false }])
      expect(bill.reload.updated_at).to eq(written_at)
      expect(bill_audits.count).to eq(audits)
    end
  end

  # An empty list is a save of nothing, the same as an empty JSON Patch.
  it 'answers an empty list of edits with 200 and the bills, and writes nothing' do
    save_edits([])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['bills']).to eq([{ 'resident_id' => cook.id, 'amount' => '0.0', 'no_cost' => false }])
  end

  # The answer's bills are read inside the save's transaction, so they are
  # what this save left. A save that commits right after (here, a bill
  # written as soon as the lock's block is done) is not in them.
  it 'answers with the bills as this save left them, not as a later save left them' do
    later = new_cook
    allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the window is inside one request
      .and_wrap_original do |original, *args, &block|
        original.call(*args, &block).tap do
          Bill.create!(meal_id: original.receiver.id, resident: later, amount: BigDecimal('1'))
        end
      end

    save_edits([changing(cook, seen, values('2.00'))])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['bills'].pluck('resident_id')).to eq([cook.id])
    expect(meal.bills.count).to eq(2)
  end

  describe 'a form-encoded body' do
    it 'takes resident ids, amounts and no_cost as the text a form sends' do
      added = new_cook

      patch "/api/v1/meals/#{meal.id}/bills", params: {
        token: token,
        edits: [changing(cook, values('0.0', no_cost: false), values('', no_cost: true)),
                adding(added, values('4.50', no_cost: false))]
      }, headers: BillEdits.key_header

      expect(response).to have_http_status(:ok)
      expect(meal.bills.reload.to_h { |b| [b.resident_id, [b.amount, b.no_cost]] })
        .to eq(cook.id => [BigDecimal('0'), true], added.id => [BigDecimal('4.5'), false])
    end

    # A form-encoded empty list arrives as one empty string. It answered
    # 500 until 2026-09-10, when the key was still bills.
    it 'refuses an empty list with 400, not 500' do
      patch "/api/v1/meals/#{meal.id}/bills", params: { token: token, edits: [] }, headers: BillEdits.key_header

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('edits must be a list of changes.')
      expect(bill.reload).to be_persisted
    end
  end

  it 'refuses a body with no edits key with 400, not 500' do
    patch "/api/v1/meals/#{meal.id}/bills", params: { token: token }, headers: BillEdits.key_header, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['message']).to eq('edits must be a list of changes.')
    expect(bill.reload).to be_persisted
  end

  describe 'a save in the old format, which lists every cook' do
    let(:outdated) do
      { 'message' => 'Nothing was saved, because this page is out of date. ' \
                     'Please reload the page and enter the costs again.',
        'type' => 'outdated' }
    end

    it 'is refused as out of date and writes nothing' do
      other = create(:bill, meal: meal, resident: new_cook, amount: BigDecimal('30'))

      patch "/api/v1/meals/#{meal.id}/bills",
            params: { bills: [{ resident_id: cook.id, amount: '12.00', no_cost: false }], token: token }, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq(outdated)
      expect(bill.reload.amount).to eq(BigDecimal('0'))
      expect(other.reload.amount).to eq(BigDecimal('30'))
    end

    it 'is refused even with edits beside it' do
      patch "/api/v1/meals/#{meal.id}/bills", params: {
        bills: [], edits: [changing(cook, seen, values('12.00'))], token: token
      }, as: :json

      expect(response.parsed_body).to eq(outdated)
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    # The old page sent an empty list form-encoded, and that arrives as
    # one empty string.
    it 'is refused when form-encoded too' do
      patch "/api/v1/meals/#{meal.id}/bills", params: { bills: [{ resident_id: cook.id }], token: token }

      expect(response.parsed_body).to eq(outdated)
    end

    it 'writes one line to the log, so old pages can be counted' do
      allow(Rails.logger).to receive(:info).and_call_original

      patch "/api/v1/meals/#{meal.id}/bills", params: { bills: [], token: token }, as: :json

      expect(Rails.logger).to have_received(:info)
        .with("Refused a bills save in the old format for meal #{meal.id}: the page was loaded before #135.")
    end
  end

  describe 'reconciled meal rejection' do
    let(:reconciliation) { create(:reconciliation, community: community) }

    before do
      meal.update!(reconciliation: reconciliation)
    end

    # The meal page reads this exact sentence to tell a settled meal from
    # the other 400s. A save for a meal the person has left then says
    # that meal was settled (#107). The sentence comes from the contract
    # file. If the server's words change, this example fails until the
    # contract file changes, and then tests/unit/api_contract.test.ts
    # fails until the constant in data_store_bills.ts changes.
    it 'returns 400 with the exact sentence the meal page reads' do
      save_edits([changing(cook, seen, values('50.00'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('message' => reconciled_rejection)
    end

    it 'does not modify the bill' do
      save_edits([changing(cook, seen, values('999.00'))])

      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    # Sending a stale edit again can never work on a settled meal, so the
    # settled words win, and so does an old page's body.
    it 'answers a stale edit and an old page with the settled words' do
      save_edits([changing(cook, values('5.0'), values('7.00'))])
      expect(response.parsed_body).to eq('message' => reconciled_rejection)

      patch "/api/v1/meals/#{meal.id}/bills", params: { bills: [], token: token }, as: :json
      expect(response.parsed_body).to eq('message' => reconciled_rejection)
    end
  end

  describe 'reconciliation racing the locked write' do
    # The reject_if_reconciled before_action reads the meal before the lock is
    # taken, so a reconciliation sweep can commit in between. The locked write
    # must then re-encounter the guards and roll back — a swept meal's bills
    # may never be deleted.
    def sweep_inside_the_lock
      # end_date predates the meal so creating the reconciliation does not
      # sweep it; the with_lock wrapper below performs the sweep inside the
      # race window instead (update_all, like the real assign_meals).
      reconciliation = create(:reconciliation, community: community, end_date: meal.date - 30)

      allow_any_instance_of(Meal).to receive(:with_lock) # rubocop:disable RSpec/AnyInstance -- the race window is inside one request
        .and_wrap_original do |original, *args, &block|
          Meal.where(id: original.receiver.id).update_all(reconciliation_id: reconciliation.id)
          original.call(*args, &block)
        end
    end

    it 'returns 400 and keeps the bill when the meal is swept after the stale check' do
      sweep_inside_the_lock

      save_edits([removing(cook, seen)])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq(reconciled_rejection)
      expect(Bill.exists?(bill.id)).to be true
    end

    # Bill's own reconciled check reads the meals table, so it would refuse
    # this write too, but with its own words ("Validation failed: Meal has
    # been reconciled."). The exact sentence below, reconciled_rejection,
    # is the one the re-check under the lock gives, so the example shows
    # that re-check answered.
    it 'returns 400 and keeps the amount when a change races the sweep' do
      sweep_inside_the_lock

      save_edits([changing(cook, seen, values('999.00'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq(reconciled_rejection)
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    # The re-check under the lock comes before the stale check.
    it 'answers a stale edit with the settled words when the sweep races it' do
      sweep_inside_the_lock

      save_edits([changing(cook, values('5.0'), values('7.00'))])

      expect(response.parsed_body).to eq('message' => reconciled_rejection)
    end
  end

  # The page sends a blank amount when a cook clears the field. The stored
  # amount starts at $25, so "blank means zero" and "blank means keep the
  # old amount" give different answers.
  describe 'blank amount' do
    before { bill.update!(amount: BigDecimal('25')) }

    it 'treats an empty string amount as zero' do
      save_edits([changing(cook, values('25.0'), values(''))])

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    # In the old format a null amount meant zero. Now an amount is text.
    it 'refuses a null amount' do
      save_edits([changing(cook, values('25.0'), values(nil))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq('Invalid amount: null. Amounts are text with whole cents, 0 to 9999.99, like "25.50".')
      expect(bill.reload.amount).to eq(BigDecimal('25'))
    end

    # In the old format a row with an amount and no no_cost key cleared
    # no_cost. Now each side carries both.
    it 'refuses a side without no_cost' do
      save_edits([changing(cook, values('25.0'), { amount: '' })])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("'from' and 'to' each need amount and no_cost.")
      expect(bill.reload.amount).to eq(BigDecimal('25'))
    end
  end

  describe 'duplicate cook rejection' do
    it 'returns 400 with the cook id in the message, and writes nothing' do
      save_edits([changing(cook, seen, values('30.00')), removing(cook, seen)])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq("Duplicate cook in edits: resident ##{cook.id}.")
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end
  end

  describe 'negative amount' do
    # The whole-cents grammar has no minus sign, so the controller rejects
    # a negative amount before any DB write.
    it 'returns 400 and leaves the bill unchanged' do
      save_edits([changing(cook, seen, values('-5.00'))])

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
      save_edits([changing(cook, seen, values('12.345'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq('Invalid amount: 12.345. Amounts are text with whole cents, 0 to 9999.99, like "25.50".')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    it 'returns 400 for an amount over 9999.99 instead of overflowing the column' do
      save_edits([changing(cook, seen, values('10000'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end

    it 'does not include bills in a refusal — no rows were written' do
      save_edits([changing(cook, seen, values('12.345'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).not_to have_key('bills')
    end

    it 'returns 400 for scientific notation' do
      save_edits([changing(cook, seen, values('1e3'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
    end

    it 'returns 400 for a sub-cent fraction that would round to zero' do
      save_edits([changing(cook, seen, values('0.000000001'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
    end

    # A from that breaks the grammar could never match a stored bill (the
    # bills_amount_whole_cents CHECK holds on every row), so it is a 400,
    # not a 409.
    it 'checks the amount the page saw too' do
      save_edits([changing(cook, values('0.001'), values('1.00'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount: 0.001.')
    end

    it 'accepts the largest whole-cent amount the column can hold' do
      save_edits([changing(cook, seen, values('9999.99'))])

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('9999.99'))
    end

    it 'accepts a single decimal digit' do
      save_edits([changing(cook, seen, values('12.5'))])

      expect(response).to have_http_status(:ok)
      expect(bill.reload.amount).to eq(BigDecimal('12.5'))
    end
  end

  # Rails reads a JSON number as a Float. 25.499999999999999 arrives as
  # the Float 25.5, its text "25.5" passes the whole-cents grammar, and
  # $25.50 was stored: a sub-cent amount rounded, not refused. The body is
  # written by hand, because a Ruby float literal is already 25.5.
  describe 'an amount sent as a JSON number' do
    def send_raw(json)
      patch "/api/v1/meals/#{meal.id}/bills", params: json,
                                              headers: { 'Authorization' => "Bearer #{token}",
                                                         'Content-Type' => 'application/json' }
                                                .merge(BillEdits.key_header)
    end

    it 'refuses it in the old format and stores nothing' do
      send_raw(%({"bills":[{"resident_id":#{cook.id},"amount":25.499999999999999,"no_cost":false}]}))

      expect(bill.reload.amount).to eq(BigDecimal('0'))
      expect(response).to have_http_status(:bad_request)
    end

    it 'refuses it in an edit and stores nothing' do
      from = '{"amount":"0.0","no_cost":false}'
      to = '{"amount":25.499999999999999,"no_cost":false}'
      send_raw(%({"edits":[{"op":"change","resident_id":#{cook.id},"from":#{from},"to":#{to}}]}))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq('Invalid amount: 25.5. Amounts are text with whole cents, 0 to 9999.99, like "25.50".')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
    end
  end

  describe 'partial failure in a multi-edit save' do
    # Atomicity rests on with_lock's implicit transaction. BillsPayload
    # checks every edit before the lock, so a bad amount never gets this
    # far; what can still fail is the write itself. Here the second cook is
    # deleted after the check (the race the InvalidForeignKey rescue is
    # for), so their new bill fails after the first cook's bill was already
    # updated. The transaction must roll that write back — a 400 response
    # must mean nothing was saved.
    it 'rolls back the earlier bill write when a later bill fails' do
      cook_2 = new_cook
      allow_any_instance_of(Bill).to receive(:save!).and_wrap_original do |save, *args, **kwargs| # rubocop:disable RSpec/AnyInstance -- BillsPayload builds the record
        raise ActiveRecord::InvalidForeignKey, 'bills_resident_id_fkey' if save.receiver.resident_id == cook_2.id

        save.call(*args, **kwargs)
      end

      save_edits([changing(cook, seen, values('30.00')), adding(cook_2, values('5.00'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Invalid cook assignment.')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
      expect(meal.bills.where(resident: cook_2)).not_to exist
    end
  end

  describe 'malformed amount' do
    it 'returns 400 for non-numeric strings and does not modify the bill' do
      bill.update!(amount: BigDecimal('25'))

      save_edits([changing(cook, values('25.0'), values('not-a-number'))])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to include('Invalid amount')
      expect(bill.reload.amount).to eq(BigDecimal('25'))
    end
  end

  describe 'authentication' do
    it 'returns 401 without a token' do
      patch "/api/v1/meals/#{meal.id}/bills", params: { edits: [changing(cook, seen, values('50.00'))] }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['message']).to include('not authenticated')
    end

    it 'returns 401 with an invalid token' do
      save_edits([changing(cook, seen, values('50.00'))], token: 'bogus-token-that-does-not-exist')

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # The warning describes what the save did: it compares the cooks before
  # the save with the cooks read from the database after it, inside the
  # lock. A save names only the cooks it changes, so the list it sent is
  # not the meal's cooks.
  describe 'third-cook warnings' do
    let(:rotation) { create(:rotation, community: community) }
    let(:future_meal) { create(:meal, community: community, date: 1.week.from_now, rotation: rotation) }
    let(:other_meal) { create(:meal, community: community, date: 2.weeks.from_now, rotation: rotation) }

    let(:cook_1) { new_cook }
    let(:cook_2) { new_cook }
    let(:cook_3) { new_cook }
    let(:cook_4) { new_cook }

    before do
      # future_meal starts with 2 cooks
      create(:bill, meal: future_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: future_meal, resident: cook_2, community: community, amount: BigDecimal('0'))
      # other_meal in the rotation has < 2 cooks (only 1)
      create(:bill, meal: other_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
    end

    def add_cook_3(target = future_meal)
      save_edits([adding(cook_3, values('0'))], meal_id: target.id)
    end

    it 'warns when adding a 3rd cook, and saves the bill' do
      add_cook_3

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq('Warning: third cooks should not be added until all meals in the rotation have at least two cooks.')
      expect(response.parsed_body['type']).to eq('warning')
      expect(future_meal.bills.count).to eq(3)
    end

    it 'includes the stored bills alongside the warning — the write happened' do
      save_edits([changing(cook_1, seen, values('10.00')), adding(cook_3, values('0'))], meal_id: future_meal.id)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['type']).to eq('warning')
      expect(response.parsed_body['bills']).to contain_exactly(
        { 'resident_id' => cook_1.id, 'amount' => '10.0', 'no_cost' => false },
        { 'resident_id' => cook_2.id, 'amount' => '0.0', 'no_cost' => false },
        { 'resident_id' => cook_3.id, 'amount' => '0.0', 'no_cost' => false }
      )
    end

    it 'warns when switching a 3rd cook' do
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      save_edits([removing(cook_3, seen), adding(cook_4, values('0'))], meal_id: future_meal.id)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message'])
        .to eq('Warning: third cook should not be switched when there are other meals in the rotation ' \
               'without at least two cooks.')
      expect(response.parsed_body['type']).to eq('warning')
      expect(future_meal.bills.find_by(resident: cook_4)).to be_present
    end

    it 'does not warn when only changing the cost of an existing 3rd cook' do
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      save_edits([changing(cook_3, seen, values('25.00'))], meal_id: future_meal.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
      expect(response.parsed_body).not_to have_key('type')
      expect(future_meal.bills.find_by(resident: cook_3).amount).to eq(BigDecimal('25'))
    end

    # PostgreSQL returns an updated row after the others, so after this
    # save the cooks come back from the database in another order than
    # their ids. The same three cooks are still cooking.
    it 'does not warn when only changing the cost of the cook with the lowest id' do
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      save_edits([changing(cook_1, seen, values('25.00'))], meal_id: future_meal.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
      expect(future_meal.bills.find_by(resident: cook_1).amount).to eq(BigDecimal('25'))
    end

    # The add is already done, so the cooks did not change.
    it 'does not warn when a 3rd cook is added again with the values stored' do
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('0'))

      add_cook_3

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end

    it 'does not warn on a stale save, which writes nothing' do
      create(:bill, meal: future_meal, resident: cook_3, community: community, amount: BigDecimal('9'))

      add_cook_3

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['type']).to eq('stale')
    end

    it 'does not warn when all rotation meals have 2+ cooks' do
      create(:bill, meal: other_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      add_cook_3

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end

    # No other meal in the rotation can be short of cooks.
    it 'does not warn for a future meal that is the only one in its rotation' do
      lone_meal = create(:meal, community: community, date: 3.weeks.from_now,
                                rotation: create(:rotation, community: community))
      create(:bill, meal: lone_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: lone_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      add_cook_3(lone_meal)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end

    it 'does not warn for past meals' do
      past_meal = create(:meal, community: community, date: 1.week.ago, rotation: rotation)
      create(:bill, meal: past_meal, resident: cook_1, community: community, amount: BigDecimal('0'))
      create(:bill, meal: past_meal, resident: cook_2, community: community, amount: BigDecimal('0'))

      add_cook_3(past_meal)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('Form submitted.')
    end
  end

  describe 'meal not found' do
    it 'returns 404 for a nonexistent meal' do
      save_edits([changing(cook, seen, values('50.00'))], meal_id: 999_999)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'a cook who does not exist' do
    it 'answers 400 before the lock and writes nothing' do
      save_edits([changing(cook, seen, values('20')), { op: 'add', resident_id: 999_999, to: values('5') }])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Resident not found.')
      expect(bill.reload.amount).to eq(BigDecimal('0'))
      expect(meal.bills.count).to eq(1)
    end

    # A remove of a cook with no bill is done, but an id that names nobody
    # is still a mistake in the request.
    it 'answers 400 for a remove too' do
      save_edits([{ op: 'remove', resident_id: 999_999, from: values('5') }])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['message']).to eq('Resident not found.')
    end
  end
end
