# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 4: the admin settlement form shows a preview first. The
# preview lists the dinners that will settle, each person's amount, and
# the dinners that will wait and why, and it has the Create button. The
# button sends the preview's fingerprint, so a settlement never saves
# amounts the admin did not see. Under the dinners that wait for a cost,
# "Mark these N blank costs as No cost" shows the list, asks yes or no,
# and changes only the costs still blank at the yes.
RSpec.describe 'Admin settlement preview' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Unit A') }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook One') }
  let(:helper) { create(:resident, community: community, unit: unit, name: 'Cook Two') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }

  before do
    host! 'admin.example.com'
    sign_in admin
  end

  def dinner(date, costs:, eaters: [eater])
    meal = create(:meal, community: community, date: date)
    costs.each do |person, amount|
      no_cost = amount == :no_cost
      create(:bill, meal: meal, resident: person, community: community,
                    amount: no_cost ? BigDecimal('0') : BigDecimal(amount.to_s), no_cost: no_cost)
    end
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    meal
  end

  def preview_path(cutoff = latest)
    "/reconciliations/preview?#{{ reconciliation: { end_date: cutoff.iso8601 } }.to_query}"
  end

  def mark_path(cutoff = latest)
    "/reconciliations/mark_no_cost?#{{ reconciliation: { end_date: cutoff.iso8601 } }.to_query}"
  end

  def page
    response.parsed_body
  end

  def panel(title)
    page.css('.panel').find { |panel| panel.at_css('h3').text.start_with?(title) }
  end

  def rows(panel)
    panel.css('tbody tr').map { |row| row.css('td').map { |cell| cell.text.squish } }
  end

  describe 'the new form' do
    it 'asks for the cutoff and opens the preview, with no Create button of its own' do
      get '/reconciliations/new'

      form = page.at_css('form#new_reconciliation')
      expect(form['action']).to eq('/reconciliations/preview')
      expect(form['method']).to eq('get')
      expect(form.css('input[type=submit]').pluck('value')).to eq(['Preview'])
      expect(form.at_css('input[type=submit]')['name']).to be_nil
    end

    it 'keeps a cutoff it is sent, for the preview\'s "Change the date" link' do
      get "/reconciliations/new?#{{ reconciliation: { end_date: latest.iso8601 } }.to_query}"

      expect(page.at_css('#reconciliation_end_date')['value']).to eq(latest.iso8601)
    end
  end

  describe 'the preview' do
    it 'shows the dinners that will settle, each person\'s amount, and the dinners that wait and why' do
      settles = dinner(latest - 3, costs: { cook => 30, helper => :no_cost })
      waits = dinner(latest - 2, costs: { cook => 20, helper => 0 })
      held = dinner(latest - 1, costs: { cook => 15 }, eaters: [])
      skipped = dinner(latest, costs: {})

      get preview_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css('h2#page_title').text).to eq('Settlement Preview')
      expect(page.text).to include("Dinners on or before #{latest.iso8601}.")
      expect(page.at_css("a[href='/reconciliations/new?#{{ reconciliation: { end_date: latest.iso8601 } }.to_query}']")
                 .text).to eq('Change the date')

      expect(panel('Dinners that will settle (1)').at_css('h3').text).to eq('Dinners that will settle (1)')
      expect(rows(panel('Dinners that will settle')))
        .to eq([[settles.date.iso8601, 'Cook One ($30.00), Cook Two (No cost)', '1', '$30.00']])
      expect(rows(panel("Each person's amount")))
        .to contain_exactly(['Cook One', 'Unit A', 'is owed $30.00'], ['Eater One', 'Unit A', 'owes $30.00'])
      expect(panel("Each person's amount").text).to include('Difference: $0.00')

      # ADR 0011 rule 7: the unit the settlement will save. Someone who has
      # moved out is under Moved out, after the units.
      eater.update!(active: false)
      get preview_path
      expect(rows(panel("Each person's amount")))
        .to eq([['Cook One', 'Unit A', 'is owed $30.00'], ['Eater One', 'Moved out', 'owes $30.00']])

      expect(panel('Dinners that will wait (3)').at_css('h3').text).to eq('Dinners that will wait (3)')
      expect(rows(panel('Dinners that will wait')).map(&:first))
        .to contain_exactly(waits.date.iso8601, held.date.iso8601, skipped.date.iso8601)
      expect(panel('Dinners that will wait').text)
        .to include("Cook Two has not entered a cost for #{waits.date.iso8601}")
        .and include("Cook One submitted a $15.00 bill for #{held.date.iso8601}, but nobody signed up")
        .and include("1 person signed up to eat on #{skipped.date.iso8601}, but no bill was submitted")

      create_button = page.at_css("form[action='/reconciliations'] button[type=submit]")
      expect(create_button.text).to eq('Create Reconciliation')
      # Off after the first click: a second Create would find nothing left
      # to settle and show an error after the first one saved.
      expect(create_button['data-disable-with']).to eq('Create Reconciliation')
      expect(page.at_css("form[action='/reconciliations'] input[name='reconciliation[end_date]']")['value'])
        .to eq(latest.iso8601)
      expect(page.at_css("form[action='/reconciliations'] input[name='fingerprint']")['value'])
        .to eq(Settlement.preview(cutoff: latest).fingerprint)
    end

    it 'offers to mark the blank costs No cost, with how many' do
      dinner(latest - 1, costs: { cook => 0, helper => 0 })
      dinner(latest, costs: { cook => 0 })

      get preview_path

      expect(page.at_css("a[href='#{mark_path}']").text).to eq('Mark these 3 blank costs as No cost')
    end

    it 'says "this blank cost" for one' do
      dinner(latest, costs: { cook => 0 })

      get preview_path

      expect(page.at_css("a[href='#{mark_path}']").text).to eq('Mark this blank cost as No cost')
    end

    it 'offers no marking when no cost is blank' do
      dinner(latest, costs: { cook => 30 })

      get preview_path

      expect(page.css("a[href='#{mark_path}']")).to be_empty
      expect(panel('Dinners that will wait (0)').text)
        .to include("No dinner on or before #{latest.iso8601} is waiting.")
    end

    # A dinner with nobody to charge never waits for a cost (ADR 0011 rule
    # 3), so it settles with its blank cost, and the preview notes it.
    it 'notes a blank cost on a dinner that settles because nobody is charged' do
      settles = dinner(latest, costs: { cook => 0 }, eaters: [])

      get preview_path

      expect(rows(panel('Dinners that will settle'))).to eq([[settles.date.iso8601, 'Cook One ($0.00)', '0', '$0.00']])
      expect(panel("Each person's amount").text).to include('Nobody owes or is owed anything.')
      expect(rows(panel('Notes')))
        .to eq([[settles.date.iso8601, "Cook One submitted a $0.00 bill but didn't mark it as a no-cost meal."]])
      expect(page.css("a[href='#{mark_path}']")).to be_empty
    end

    it 'has no Create button when nothing can settle, and says why' do
      waits = dinner(latest, costs: { cook => 0 })

      get preview_path

      expect(panel('Dinners that will settle (0)').text)
        .to include("No dinner on or before #{latest.iso8601} can be settled now.")
      expect(rows(panel('Dinners that will wait')).map(&:first)).to eq([waits.date.iso8601])
      expect(page.css("form[action='/reconciliations']")).to be_empty
      expect(page.text).to include('Nothing can be settled with this date, so there is no Create button.')
    end

    it 'shows the form again with the reason for a cutoff less than 14 days back' do
      get preview_path(latest + 1)

      expect(response).to have_http_status(:ok)
      expect(page.at_css('#reconciliation_end_date_input .inline-errors').text)
        .to eq("must be on or before #{latest.iso8601}, 14 days before today")
      expect(page.at_css('form#new_reconciliation')['action']).to eq('/reconciliations/preview')
    end

    it 'shows the form again when no date was picked' do
      get '/reconciliations/preview?reconciliation[end_date]='

      expect(page.at_css('#reconciliation_end_date_input .inline-errors').text).to eq("can't be blank")
    end
  end

  describe 'Create' do
    let!(:meal) { dinner(latest, costs: { cook => 30 }) }

    it 'settles what the preview showed' do
      expect { post '/reconciliations', params: admin_settle_params(latest) }.to change(Reconciliation, :count).by(1)

      expect(response).to redirect_to("/reconciliations/#{Reconciliation.sole.id}")
      expect(meal.reload.reconciliation_id).to eq(Reconciliation.sole.id)
      # The meal's history says it was settled, and by whom (Settlement#record_meals_settled).
      expect(meal.audits.where(action: 'update').reorder(:id).last)
        .to have_attributes(user: admin, audited_changes: { 'reconciliation_id' => [nil, Reconciliation.sole.id] })
    end

    it 'saves nothing, and shows the preview as it is now, when a cost changed after the preview' do
      params = admin_settle_params(latest)
      meal.bills.sole.update!(amount: BigDecimal('31'))

      expect { post '/reconciliations', params: params }.not_to change(Reconciliation, :count)

      expect(response).to redirect_to(preview_path)
      expect(flash[:alert]).to eq('A cost or a sign-up changed after this preview was made, so nothing was saved. ' \
                                  'This is the preview as it is now. Look it over, then click Create again.')
      expect(meal.reload.reconciliation_id).to be_nil
    end

    it 'sends a create that did not come from a preview to the preview' do
      expect { post '/reconciliations', params: { reconciliation: { end_date: latest } } }
        .not_to change(Reconciliation, :count)

      expect(response).to redirect_to(preview_path)
      expect(flash[:alert]).to eq('Look over the preview first, then click Create.')
    end

    it 'sends a create with no date and no preview to the new form' do
      expect { post '/reconciliations', params: { reconciliation: { end_date: '' } } }
        .not_to change(Reconciliation, :count)

      expect(response).to redirect_to('/reconciliations/new')
    end
  end

  describe 'marking blank costs No cost' do
    it 'lists each blank cost and asks yes or no' do
      free = dinner(latest - 1, costs: { cook => 0, helper => :no_cost })
      paid = dinner(latest, costs: { cook => 20, helper => 0 })

      get mark_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css('h2#page_title').text).to eq('Mark Blank Costs as No Cost')
      free_note = 'No cook on this dinner has entered an amount. After this, it is free for everyone who ate.'
      expect(rows(panel('Blank costs (2)')))
        .to eq([[free.date.iso8601, 'Cook One', free_note], [paid.date.iso8601, 'Cook Two', '']])
      expect(page.text).to include('Mark these 2 costs No cost?')
      yes = page.at_css("form[action='/reconciliations/mark_no_cost']")
      expect(yes.at_css('input[type=submit]')['value']).to eq('Yes, mark them No cost')
      expect(yes.at_css('input[type=submit]')['data-disable-with']).to eq('Yes, mark them No cost')
      expect(yes.css("input[name='bill_ids[]']").map { |input| input['value'].to_i })
        .to eq([free.bills.find_by(resident: cook).id, paid.bills.find_by(resident: helper).id])
      expect(yes.at_css("li.cancel a[href='#{preview_path}']").text).to eq('No, go back')
    end

    it 'goes back to the preview when no cost is blank' do
      dinner(latest, costs: { cook => 20 })

      get mark_path

      expect(response).to redirect_to(preview_path)
      expect(flash[:notice]).to eq('No cost is blank on a dinner that waits.')
    end

    it 'marks the listed costs that are still blank, records the admin, and says what it did' do
      meal = dinner(latest, costs: { cook => 0, helper => 0 })
      blank, entered = meal.bills.order(:id).to_a
      entered.update!(amount: BigDecimal('12'))

      post '/reconciliations/mark_no_cost',
           params: { reconciliation: { end_date: latest.iso8601 }, bill_ids: [blank.id, entered.id] }

      expect(response).to redirect_to(preview_path)
      expect(flash[:notice]).to eq("Marked 1 cost as No cost. Left alone: #{latest.iso8601}, " \
                                   "#{entered.resident.name}, because the cook entered a cost.")
      expect(blank.reload.no_cost).to be(true)
      expect(entered.reload).to have_attributes(no_cost: false, amount: BigDecimal('12'))
      expect(blank.audits.last.user).to eq(admin)
    end

    it 'sends a request with no usable date back to the new form' do
      get '/reconciliations/mark_no_cost?reconciliation[end_date]=soon'

      expect(response).to redirect_to('/reconciliations/new')
      expect(flash[:alert]).to eq('Pick a cutoff date first.')
    end

    # Date.iso8601 took "--10-12", with no year, and filled the year in
    # from the machine's own clock, not from the community's today. The
    # preview page links here with the cutoff written as YYYY-MM-DD, so
    # anything else did not come from it (YearMonthDay).
    it 'sends a cutoff with no year back to the new form' do
      get '/reconciliations/mark_no_cost?reconciliation[end_date]=--10-12'

      expect(response).to redirect_to('/reconciliations/new')
      expect(flash[:alert]).to eq('Pick a cutoff date first.')
    end
  end

  describe 'who may use them' do
    def expect_denied
      expect(response).to redirect_to('http://admin.example.com/')
      expect(flash[:error]).to eq('You are not authorized to perform this action.')
    end

    context 'when signed in as a plain admin' do
      before { sign_in create(:admin_user, community: community, superuser: false) }

      it 'may not open the preview' do
        get preview_path

        expect_denied
      end

      it 'may not mark costs No cost' do
        blank = dinner(latest, costs: { cook => 0 }).bills.sole

        get mark_path
        expect_denied

        post '/reconciliations/mark_no_cost',
             params: { reconciliation: { end_date: latest.iso8601 }, bill_ids: [blank.id] }
        expect_denied
        expect(blank.reload.no_cost).to be(false)
      end
    end

    context 'with the read-only token' do
      # The token's account is a superuser: the token reads, whatever the
      # account may do (ADR 0004).
      before do
        sign_out admin
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('read-only')
        allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin.id.to_s)
      end

      it 'may not open the preview or the marking page' do
        get "#{preview_path}&token=read-only"
        expect_denied

        get "#{mark_path}&token=read-only"
        expect_denied
      end
    end
  end
end
