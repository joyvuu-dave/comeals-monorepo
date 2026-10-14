# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 8 on the settlement page: each line can be marked Paid or
# Let go, with a note. Any admin may mark a line Paid; setting or changing
# a Let go mark needs a superuser. The page shows each line's mark and the
# history of every change, and a read-only link sees them with no form.
RSpec.describe 'Admin settlement line marks' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community, name: 'Elm') }
  let(:superuser) { create(:admin_user, community: community, superuser: true, email: 'books@example.com') }
  let(:admin) { create(:admin_user, community: community, superuser: false, email: 'helper@example.com') }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Casey Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Dana Diner') }
  let!(:reconciliation) do
    meal = create(:meal, community: community, date: Reconciliation.latest_cutoff(community.today))
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    settle!
  end
  let(:line) { reconciliation.reconciliation_balances.find_by!(resident: eater) }
  let(:path) { "/reconciliations/#{reconciliation.id}" }

  before { host! 'admin.example.com' }

  def page
    response.parsed_body
  end

  def mark(status, note: nil, seen: line.reload.newest_mark&.id)
    post '/settlement_line_marks', params: { line_id: line.id, status: status, note: note, seen: seen }
  end

  def row(name)
    page.css('.panel').find { |panel| panel.at_css('h3').text == 'Settlement Balances' }
        .css('tbody tr').find { |tr| tr.at_css('td').text.strip == name }
  end

  def mark_cell(name)
    row(name).at_css('td.col-mark').text.squish
  end

  it 'lets any admin mark a line Paid, with a note, and shows it with who and when' do
    sign_in admin

    expect { mark('paid', note: 'paid $20 of $30') }.to change(SettlementLineMark, :count).by(1)

    expect(response).to redirect_to(path)
    expect(flash[:notice]).to eq('Dana Diner: Paid.')
    follow_redirect!
    expect(mark_cell('Dana Diner'))
      .to eq("Paid paid $20 of $30 by helper@example.com, #{Time.current.strftime('%b %-d, %Y')}")
    expect(mark_cell('Casey Cook')).to eq('')
    history = page.css('.panel').find { |panel| panel.at_css('h3').text == 'Marks (1)' }
    expect(history.css('tbody td').map { |td| td.text.strip }.drop(1))
      .to eq(['Dana Diner', 'Paid', 'paid $20 of $30', 'helper@example.com'])
  end

  it 'offers a plain admin Paid and No mark, and a superuser Let go too' do
    sign_in admin
    get path
    expect(row('Dana Diner').css('select option').map(&:text)).to eq(['Paid', 'No mark'])

    sign_in superuser
    get path
    expect(row('Dana Diner').css('select option').map(&:text)).to eq(['Paid', 'Let go', 'No mark'])
  end

  it 'lets only a superuser mark a line Let go' do
    sign_in admin
    expect { mark('let_go') }.not_to change(SettlementLineMark, :count)
    expect(flash[:error]).to eq('You are not authorized to perform this action.')

    sign_in superuser
    expect { mark('let_go', note: 'Moved away') }.to change(SettlementLineMark, :count).by(1)
    expect(line.reload.current_mark.status).to eq('let_go')
  end

  it 'lets only a superuser change a line marked Let go' do
    sign_in superuser
    mark('let_go')

    sign_in admin
    get path
    expect(row('Dana Diner').at_css('td.col-change_mark').text.squish)
      .to eq('Only a superuser can change a Let go mark.')
    expect { mark('paid') }.not_to change(SettlementLineMark, :count)
    expect(flash[:error]).to eq('You are not authorized to perform this action.')
  end

  it 'saves nothing when the line was marked after the page was loaded, and says so' do
    sign_in admin
    get path
    seen = row('Dana Diner').at_css('input[name=seen]')['value'].presence
    mark('paid', seen: seen)

    expect { mark('none', seen: seen) }.not_to change(SettlementLineMark, :count)
    expect(flash[:alert]).to start_with("Someone changed this line's mark after the page was loaded")
  end

  it 'says so when nothing changes, and when a status is unknown' do
    sign_in admin
    mark('none')
    expect(flash[:alert]).to eq('This line has no mark already.')

    mark('forgiven')
    expect(flash[:alert]).to eq('Status must be Paid, Let go or No mark')
  end

  it 'shows the marks to a read-only link, with no form, and refuses a mark from it' do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('the-token')
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(superuser.id.to_s)
    SettlementLineMarking.mark!(line, status: 'paid', note: nil, by: admin, seen: nil)

    get path, params: { token: 'the-token' }
    expect(mark_cell('Dana Diner')).to start_with('Paid by helper@example.com')
    expect(page.css('td.col-change_mark, form.settlement-mark')).to be_empty

    expect do
      post '/settlement_line_marks', params: { token: 'the-token', line_id: line.id, status: 'none',
                                               seen: line.newest_mark.id }
    end.not_to change(SettlementLineMark, :count)
  end

  it 'refuses to delete an admin who made a mark, and says why' do
    sign_in admin
    mark('paid')
    sign_in superuser

    expect { delete "/admin_users/#{admin.id}" }.not_to change(AdminUser, :count)
    follow_redirect!
    expect(response.body).to include('settlement line marks')
  end
end
