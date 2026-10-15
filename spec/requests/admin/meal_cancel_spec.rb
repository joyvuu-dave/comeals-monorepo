# frozen_string_literal: true

require 'rails_helper'

# Cancel and Restore on the admin meal page (ADR 0011 rule 11). Any admin
# may use them, because neither moves money (ADR 0004's exception); the
# read-only link may not. Each button asks first, and a refusal shows the
# model's sentence.
RSpec.describe 'Admin meal Cancel and Restore' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:admin) { create(:admin_user, community: community, superuser: false) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  before { host! 'admin.example.com' }

  def buttons
    response.parsed_body.css('.action_items a').to_h { |link| [link.text, link['data-confirm']] }
  end

  it 'lets a plain admin cancel a dinner and restore it, each asking first' do
    sign_in admin
    get "/meals/#{meal.id}"
    expect(buttons).to include('Cancel' => 'Cancel this dinner?')
    expect(buttons).not_to have_key('Restore')

    post "/meals/#{meal.id}/cancel"
    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(flash[:notice]).to eq('Dinner cancelled.')
    expect(meal.reload).to be_cancelled

    follow_redirect!
    expect(buttons).to include('Restore' => 'Restore this dinner?')
    expect(buttons).not_to have_key('Cancel')
    expect(response.parsed_body.at_css('tr.row-cancelled td').text)
      .to eq(meal.cancelled_at.strftime('%b %-d, %Y %-l:%M %p'))

    post "/meals/#{meal.id}/restore"
    expect(flash[:notice]).to eq('Dinner restored.')
    expect(meal.reload).not_to be_cancelled
  end

  it 'shows the sentence when a cook spent money on the dinner' do
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('15'))
    sign_in admin

    post "/meals/#{meal.id}/cancel"

    expect(flash[:alert]).to eq("A cook spent money on this dinner, so it can't be cancelled.")
    expect(meal.reload).not_to be_cancelled
  end

  it 'refuses the read-only link' do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('the-token')
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(admin.id.to_s)

    get "/meals/#{meal.id}", params: { token: 'the-token' }
    expect(buttons.keys & %w[Cancel Restore]).to be_empty

    post "/meals/#{meal.id}/cancel", params: { token: 'the-token' }
    expect(meal.reload).not_to be_cancelled
  end

  it 'offers neither on a settled dinner, nor a correction of a cancelled one' do
    superuser = create(:admin_user, community: community, superuser: true)
    meal.update!(date: Reconciliation.latest_cutoff(community.today))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    meal.cancel!
    settle!
    sign_in superuser

    get "/meals/#{meal.id}"
    expect(buttons.keys & ['Cancel', 'Restore', 'Correct this dinner']).to be_empty

    get "/meals/#{meal.id}/correct"
    expect(flash[:alert]).to eq('This dinner was cancelled, so it charged nobody and has nothing to correct.')
  end

  it 'marks a cancelled dinner on the dashboard, upcoming or closed' do
    meal.update!(date: community.today + 3)
    meal.cancel!
    closed = create(:meal, community: community, date: community.today - 2)
    create(:bill, meal: closed, resident: cook, community: community, amount: 0)
    closed.update!(closed: true)
    closed.cancel!
    sign_in admin

    get '/'

    lists = response.parsed_body.css('.panel').to_h do |panel|
      [panel.at_css('h3').text.split.first, panel.css('li').map { |li| li.text.squish }]
    end
    expect(lists.fetch('Upcoming')).to include("#{meal.date} (cancelled)")
    expect(lists.fetch('Closed')).to include("#{closed.date} (cancelled)")
  end
end
