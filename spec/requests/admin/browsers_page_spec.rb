# frozen_string_literal: true

require 'rails_helper'

# The Browsers page: page loads by month, browser, version, system,
# device and the browser check's result, from browser_counts. Any admin
# may read it. The read-only token in the settlement emails may not: the
# emails do not link to it (SuperuserAdapter::TOKEN_READABLE_PAGES).
RSpec.describe 'Admin browsers page' do
  let(:community) { create(:community) }
  let(:key) { { browser: 'Safari', major: 15, os: 'iPadOS', device: 'tablet', result: 'failed' } }

  before do
    host! 'admin.example.com'
    2.times { BrowserCount.add_one!(date: Date.new(2026, 10, 3), **key) }
    BrowserCount.add_one!(date: Date.new(2026, 9, 30), **key, browser: 'Chrome', major: nil, result: 'passed')
  end

  def row_texts
    response.parsed_body.css('table tbody tr').map { |row| row.css('td').map { |cell| cell.text.strip } }
  end

  it 'shows a plain admin the page loads by month, newest month first' do
    sign_in create(:admin_user, community: community)

    get '/browsers'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('October 2026', 'September 2026')
    expect(row_texts).to eq([
                              %w[Safari 15 iPadOS tablet failed 2],
                              %w[Chrome unknown iPadOS tablet passed 1]
                            ])
  end

  it 'says so when no page load has been counted yet' do
    BrowserCount.delete_all
    sign_in create(:admin_user, community: community)

    get '/browsers'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('No page loads have been counted yet.')
  end

  it 'is in the menu' do
    sign_in create(:admin_user, community: community)

    get '/'

    expect(response.parsed_body.css('#header a').map(&:text)).to include('Browsers')
  end

  describe 'the read-only token' do
    let(:token) { 'test-readonly-token' }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil)
                                   .and_return(create(:admin_user, community: community).id.to_s)
    end

    it 'may not read it' do
      get '/browsers', params: { token: token }

      expect(response).to redirect_to('http://admin.example.com/')
      expect(flash[:error]).to eq('You are not authorized to perform this action.')
    end
  end
end
