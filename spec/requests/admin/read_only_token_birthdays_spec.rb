# frozen_string_literal: true

require 'rails_helper'

# The read-only token reads the residents pages, because the settlement
# emails link to them. It must not show a birthday on any of them, in any
# format: a link mailed to the whole community must not be a list of
# everyone's date of birth (ADR 0004 §3). What the token may see is the
# price band ("Adult", "Child"), which is what the settlement is about.
# A signed-in admin still sees the birthday, and edits it.
RSpec.describe 'Birthdays on the read-only token' do
  let(:community) { create(:community) }
  let(:token) { 'test-readonly-token' }
  let(:token_account) { create(:admin_user, community: community, superuser: false) }
  let(:unit) { create(:unit, community: community) }
  # A date no other value on these pages can contain. Every way the
  # admin writes a date: the ISO form (CSV, JSON) and the long form
  # (config.localize_format, the HTML pages).
  let!(:ann) { create(:resident, community: community, unit: unit, name: 'Ann Adult', birthday: Date.new(1957, 6, 5)) }
  let(:birthday_forms) { ['1957-06-05', 'June 05, 1957', '1957'] }

  before do
    # A second resident, with no birthday, so a filter has someone to drop.
    create(:resident, community: community, unit: unit, name: 'Bob Adult')
    host! 'admin.example.com'
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(token_account.id.to_s)
  end

  def body_of(path, params = {})
    get path, params: params.merge(token: token)
    expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
    response.body
  end

  def birthday_in?(body)
    birthday_forms.any? { |form| body.include?(form) }
  end

  it 'shows no birthday on the residents list' do
    body = body_of('/residents')

    expect(birthday_in?(body)).to be(false)
    expect(response.parsed_body.css('th').map { |th| th.text.strip }).not_to include('Birthday')
    expect(body).to include('Ann Adult')
  end

  it "shows no birthday on a resident's page" do
    body = body_of("/residents/#{ann.id}")

    expect(birthday_in?(body)).to be(false)
    expect(response.parsed_body.css('th').map { |th| th.text.strip }).not_to include('Birthday')
    expect(body).to include('Ann Adult')
  end

  it 'gets the residents CSV with no birthday column' do
    body = body_of('/residents.csv')
    headers = body.delete_prefix("\uFEFF").lines.first.chomp.split(',')

    expect(birthday_in?(body)).to be(false)
    expect(headers).not_to include('Birthday')
    expect(headers).to include('Name', 'Active')
    expect(body).to include('Ann Adult')
  end

  it 'gets the residents JSON with no birthday, on the list and on a resident' do
    list = JSON.parse(body_of('/residents.json'))
    one = JSON.parse(body_of("/residents/#{ann.id}.json"))

    expect(list.map { |row| row.key?('birthday') }).to eq([false, false])
    expect(one).not_to have_key('birthday')
    expect(one['name']).to eq('Ann Adult')
  end

  # There is no XML download of any page (download_formats_spec.rb).
  it 'is refused the XML of the residents list and of a resident' do
    get '/residents.xml', params: { token: token }
    expect(response).to have_http_status(:unauthorized)

    get "/residents/#{ann.id}.xml", params: { token: token }
    expect(response).to have_http_status(:unauthorized)
  end

  # A filter or a sort on the birthday would tell the date without
  # showing it: try a date, and see who is left.
  it 'cannot filter the residents by birthday' do
    body = body_of('/residents', q: { birthday_eq: '1957-06-05' })

    expect(body).to include('Ann Adult', 'Bob Adult')
  end

  it 'cannot sort the residents by birthday' do
    names = lambda do |order|
      body_of('/residents', order: order)
      response.parsed_body.css('td.col-name').map { |td| td.text.strip }
    end

    expect(names.call('birthday_asc')).to eq(names.call('birthday_desc'))
  end

  context 'when an admin signs in' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it 'still shows the birthday on every format' do
      get '/residents'
      expect(response.body).to include('June 05, 1957')
      get "/residents/#{ann.id}"
      expect(response.body).to include('June 05, 1957')
      get '/residents.csv'
      expect(response.body).to include('1957-06-05')
      get "/residents/#{ann.id}.json"
      expect(response.parsed_body['birthday']).to eq('1957-06-05')
    end
  end
end
