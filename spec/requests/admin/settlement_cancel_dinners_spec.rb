# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 11: under the dinners that wait on the settlement
# preview, "Mark these N dinners as cancelled" lists the past dinners
# people signed up for and no cook did, asks yes or no, and cancels only
# the ones that still have no cook at the yes. Only a superuser may use
# it, like the preview it is on.
RSpec.describe 'Admin settlement preview, marking dinners cancelled' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Unit A') }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook One') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater One') }
  let(:other) { create(:resident, community: community, unit: unit, name: 'Eater Two') }

  before do
    host! 'admin.example.com'
    sign_in admin
  end

  # A past dinner people signed up for, and no cook.
  def dinner(date, eaters: [eater], guests: 0)
    meal = create(:meal, community: community, date: date)
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    guests.times { create(:guest, meal: meal, resident: eaters.first) }
    meal
  end

  def preview_path(cutoff = latest)
    "/reconciliations/preview?#{{ reconciliation: { end_date: cutoff.iso8601 } }.to_query}"
  end

  def mark_path(cutoff = latest)
    "/reconciliations/mark_cancelled?#{{ reconciliation: { end_date: cutoff.iso8601 } }.to_query}"
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

  describe 'the preview' do
    it 'offers to mark the dinners with no cook as cancelled, with how many' do
      dinner(latest - 1)
      dinner(latest)

      get preview_path

      expect(page.at_css("a[href='#{mark_path}']").text).to eq('Mark these 2 dinners as cancelled')
      expect(page.text).to include('If a dinner with no cook did not happen, mark it cancelled.')
    end

    it 'says "this dinner" for one, and offers nothing when every dinner has a cook' do
      dinner(latest)
      get preview_path
      expect(page.at_css("a[href='#{mark_path}']").text).to eq('Mark this dinner as cancelled')

      create(:bill, meal: Meal.sole, resident: cook, community: community, amount: BigDecimal('20'))
      get preview_path
      expect(page.css("a[href='#{mark_path}']")).to be_empty
    end
  end

  describe 'the list' do
    it 'lists each dinner with no cook and how many signed up, and asks yes or no' do
      two = dinner(latest - 1, eaters: [eater, other])
      with_a_guest = dinner(latest, guests: 1)

      get mark_path

      expect(response).to have_http_status(:ok)
      expect(page.at_css('h2#page_title').text).to eq('Mark Dinners as Cancelled')
      expect(rows(panel('Dinners with no cook (2)')))
        .to eq([[two.date.iso8601, '2'], [with_a_guest.date.iso8601, '2']])
      expect(page.text).to include('Mark these 2 dinners as cancelled?')
      yes = page.at_css("form[action='/reconciliations/mark_cancelled']")
      expect(yes.at_css('input[type=submit]')['value']).to eq('Yes, mark them as cancelled')
      expect(yes.at_css('input[type=submit]')['data-disable-with']).to eq('Yes, mark them as cancelled')
      expect(yes.css("input[name='meal_ids[]']").map { |input| input['value'].to_i }).to eq([two.id, with_a_guest.id])
      expect(yes.at_css("input[name='reconciliation[end_date]']")['value']).to eq(latest.iso8601)
      expect(yes.at_css("li.cancel a[href='#{preview_path}']").text).to eq('No, go back')
    end

    it 'says "this dinner" and "it" for one' do
      dinner(latest)

      get mark_path

      expect(page.text).to include('Mark this dinner as cancelled?')
      expect(page.at_css('input[type=submit]')['value']).to eq('Yes, mark it as cancelled')
    end

    it 'goes back to the preview when every dinner has a cook' do
      create(:bill, meal: dinner(latest), resident: cook, community: community, amount: BigDecimal('20'))

      get mark_path

      expect(response).to redirect_to(preview_path)
      expect(flash[:notice]).to eq('No dinner that waits is missing a cook.')
    end
  end

  describe 'the yes' do
    it 'cancels the listed dinners that still have no cook, records the admin, and says what it did' do
      nobody_cooked = dinner(latest - 1)
      cooked = dinner(latest)
      create(:bill, meal: cooked, resident: cook, community: community, amount: 0)

      post '/reconciliations/mark_cancelled',
           params: { reconciliation: { end_date: latest.iso8601 }, meal_ids: [nobody_cooked.id, cooked.id] }

      expect(response).to redirect_to(preview_path)
      expect(flash[:notice]).to eq("Marked 1 dinner as cancelled. Left alone: #{latest.iso8601}, " \
                                   'because a cook signed up for it.')
      expect(nobody_cooked.reload.cancelled?).to be(true)
      expect(cooked.reload.cancelled?).to be(false)
      expect(nobody_cooked.audits.last.user).to eq(admin)
    end

    it 'sends a request with no usable date back to the new form' do
      get '/reconciliations/mark_cancelled?reconciliation[end_date]=soon'

      expect(response).to redirect_to('/reconciliations/new')
      expect(flash[:alert]).to eq('Pick a cutoff date first.')
    end

    # Date.iso8601 took "--10-12", with no year, and filled the year in
    # from the machine's own clock, not from the community's today. The
    # preview page links here with the cutoff written as YYYY-MM-DD, so
    # anything else did not come from it (YearMonthDay).
    it 'sends a cutoff with no year back to the new form' do
      get '/reconciliations/mark_cancelled?reconciliation[end_date]=--10-12'

      expect(response).to redirect_to('/reconciliations/new')
      expect(flash[:alert]).to eq('Pick a cutoff date first.')
    end
  end

  describe 'who may use it' do
    def expect_denied
      expect(response).to redirect_to('http://admin.example.com/')
      expect(flash[:error]).to eq('You are not authorized to perform this action.')
    end

    # A plain admin may cancel one dinner from its own page (ADR 0004's
    # exception), but this button is part of settling.
    it 'is refused to a plain admin' do
      meal = dinner(latest)
      sign_in create(:admin_user, community: community, superuser: false)

      get mark_path
      expect_denied

      post '/reconciliations/mark_cancelled',
           params: { reconciliation: { end_date: latest.iso8601 }, meal_ids: [meal.id] }
      expect_denied
      expect(meal.reload.cancelled?).to be(false)
    end

    # The token's account is a superuser: the token reads, whatever the
    # account may do (ADR 0004).
    it 'is refused to the read-only token' do
      meal = dinner(latest)
      sign_out admin
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('read-only')
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin.id.to_s)

      get "#{mark_path}&token=read-only"
      expect_denied

      post '/reconciliations/mark_cancelled?token=read-only',
           params: { reconciliation: { end_date: latest.iso8601 }, meal_ids: [meal.id] }
      expect_denied
      expect(meal.reload.cancelled?).to be(false)
    end
  end
end
