# frozen_string_literal: true

require 'rails_helper'

# POST /api/v1/browser-reports is where the browser check in index.html
# (app/frontend/browser_check.js) sends its one report per page load. The
# whole report is in the query string; the browser is read from the
# User-Agent header. No login: the check runs before anyone signs in.
#
# The request only checks the report and queues BrowserReportJob. The job
# alerts the owner, outside the request, so the alert carries no request
# data and so no IP address.
RSpec.describe 'POST /api/v1/browser-reports' do
  include ActiveJob::TestHelper

  include ActiveSupport::Testing::TimeHelpers

  let(:path) { '/api/v1/browser-reports' }

  let(:iphone_safari) do
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 ' \
      '(KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1'
  end
  let(:old_ipad_safari) do
    'Mozilla/5.0 (iPad; CPU OS 15_7 like Mac OS X) AppleWebKit/605.1.15 ' \
      '(KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1'
  end
  # An iPad's Safari since iPadOS 13 sends the same string as a Mac's.
  let(:mac_safari) do
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 ' \
      '(KHTML, like Gecko) Version/18.6 Safari/605.1.15'
  end
  let(:googlebot) { 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' }

  before { create(:community, timezone: 'America/Los_Angeles') }

  def send_report(query, user_agent: iphone_safari, headers: {}, **)
    post("#{path}?#{query}", headers: { 'User-Agent' => user_agent, 'REMOTE_ADDR' => '203.0.113.9' }.merge(headers), **)
  end

  def enqueued_reports
    enqueued_jobs.select { |job| job[:job] == BrowserReportJob }
  end

  it 'takes a passing report with no login and queues it' do
    send_report('result=passed&touch=0')

    expect(response).to have_http_status(:no_content)
    expect(BrowserReportJob).to have_been_enqueued.with(
      hash_including(result: 'passed', tests: [], browser: 'Safari', major: 18, os: 'iOS', device: 'phone')
    )
  end

  it 'queues a failed report with the tests that failed' do
    send_report('result=failed&tests=lookbehind,color_mix&touch=0', user_agent: old_ipad_safari)

    expect(response).to have_http_status(:no_content)
    expect(BrowserReportJob).to have_been_enqueued.with(
      hash_including(result: 'failed', tests: %w[lookbehind color_mix],
                     browser: 'Safari', major: 15, os: 'iPadOS', device: 'tablet')
    )
  end

  it 'queues a report from a check that broke, with its error' do
    send_report('result=error&error=TypeError%3A%20boom&touch=0')

    expect(response).to have_http_status(:no_content)
    expect(BrowserReportJob).to have_been_enqueued.with(hash_including(result: 'error', error: 'TypeError: boom'))
  end

  # The app's code did not load, even after one reload. The error names
  # the file.
  it 'queues a report of an app that did not load, with the file' do
    send_report('result=load_failed&error=Could%20not%20load%20%2Fvite-assets%2Findex-abc.js&touch=0')

    expect(response).to have_http_status(:no_content)
    expect(BrowserReportJob).to have_been_enqueued.with(
      hash_including(result: 'load_failed', tests: [], error: 'Could not load /vite-assets/index-abc.js')
    )
  end

  # The day the page loaded, in the community's zone (Community#today),
  # and not the day the job happens to run. 03:00 UTC on October 22 is
  # still October 21 in the community.
  it 'dates the report by the community\'s day when it arrives' do
    travel_to(Time.utc(2026, 10, 22, 3, 0, 0)) { send_report('result=passed&touch=0') }

    expect(BrowserReportJob).to have_been_enqueued.with(hash_including(date: Date.new(2026, 10, 21)))
  end

  it 'never passes the IP address on' do
    send_report('result=failed&tests=lookbehind&touch=0')

    expect(enqueued_reports.to_s).not_to include('203.0.113.9')
  end

  # Each page load sends one report, so a reload sends a second one, and
  # that is a second page load.
  it 'queues each report, so a reload is a second page load' do
    2.times { send_report('result=passed&touch=0') }

    expect(enqueued_reports.size).to eq(2)
  end

  describe 'reading the browser' do
    def queued_browser
      enqueued_reports.last[:args].first.slice('browser', 'major', 'os', 'device')
    end

    it 'reads an iPad from a Mac string and a touch screen' do
      send_report('result=passed&touch=1', user_agent: mac_safari)

      expect(queued_browser).to eq('browser' => 'Safari', 'major' => 18, 'os' => 'iPadOS', 'device' => 'tablet')
    end

    it 'reads a Mac from a Mac string and no touch screen' do
      send_report('result=passed&touch=0', user_agent: mac_safari)

      expect(queued_browser).to eq('browser' => 'Safari', 'major' => 18, 'os' => 'macOS', 'device' => 'desktop')
    end

    it 'counts a browser it does not know as unknown' do
      send_report('result=passed&touch=0', user_agent: 'SomethingNew/3')

      expect(queued_browser).to eq('browser' => 'Unknown', 'major' => nil, 'os' => 'Unknown', 'device' => 'unknown')
    end

    # Every browser sends a User-Agent header. A request with none, or
    # with curl's, is a script.
    it 'answers a request with no User-Agent, or a script\'s, and queues nothing' do
      send_report('result=failed&tests=lookbehind&touch=0', user_agent: '')
      send_report('result=failed&tests=lookbehind&touch=0', user_agent: 'curl/8.4.0')

      expect(response).to have_http_status(:no_content)
      expect(enqueued_reports).to be_empty
    end

    it 'reads only the start of a very long User-Agent string' do
      send_report('result=failed&tests=lookbehind&touch=0', user_agent: "#{iphone_safari} #{'x' * 5000}")

      expect(response).to have_http_status(:no_content)
      args = enqueued_reports.last[:args].first
      expect(args['browser']).to eq('Safari')
      expect(args['user_agent'].length).to eq(BrowserReport::MAX_USER_AGENT)
    end

    # The check's report is for people's browsers. A crawler that runs
    # the page's scripts is not a resident, and its browser says nothing
    # about who can use the app.
    it 'answers a crawler and queues nothing' do
      send_report('result=failed&tests=lookbehind&touch=0', user_agent: googlebot)

      expect(response).to have_http_status(:no_content)
      expect(enqueued_reports).to be_empty
    end
  end

  describe 'refusing what the check never sends' do
    [
      ['no result', 'touch=0'],
      ['an unknown result', 'result=maybe&touch=0'],
      ['a failed report with no tests', 'result=failed&touch=0'],
      ['a failed report with an empty test list', 'result=failed&tests=&touch=0'],
      ['an unknown test', 'result=failed&tests=lookbehind,flying&touch=0'],
      ['the same test twice', 'result=failed&tests=cookies,cookies&touch=0'],
      ['tests on a passing report', 'result=passed&tests=cookies&touch=0'],
      ['an error on a passing report', 'result=passed&error=boom&touch=0'],
      ['an error report with no error', 'result=error&touch=0'],
      ['an error longer than the check sends', "result=error&error=#{'x' * 201}&touch=0"],
      ['a load_failed report with no error', 'result=load_failed&touch=0'],
      ['a load_failed report with tests', 'result=load_failed&tests=cookies&error=x&touch=0'],
      ['a load_failed error longer than the check sends', "result=load_failed&error=#{'x' * 201}&touch=0"],
      ['no touch', 'result=passed'],
      ['a touch that is not 0 or 1', 'result=passed&touch=2'],
      ['a list where one value is expected', 'result[]=passed&touch=0']
    ].each do |name, query|
      it "refuses #{name}, and queues nothing" do
        send_report(query)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body['message']).to be_present
        expect(enqueued_reports).to be_empty
      end
    end

    # Rack::Attack limits alerts by the result in the query string. A
    # result sent in a form body would get past that limit.
    it 'reads the report from the query string only, not from a form body' do
      send_report('touch=0', params: { result: 'failed', tests: 'lookbehind' })

      expect(response).to have_http_status(:bad_request)
      expect(enqueued_reports).to be_empty
    end

    # The check sends no body. A body is someone else's request.
    it 'refuses a body larger than a kilobyte' do
      send_report('result=passed&touch=0', params: 'x' * 2.kilobytes,
                                           headers: { 'CONTENT_TYPE' => 'text/plain' })

      expect(response).to have_http_status(:content_too_large)
      expect(enqueued_reports).to be_empty
    end

    # A browser says where a request came from. The check's report always
    # comes from the app's own page.
    it 'refuses a report sent from another site' do
      send_report('result=failed&tests=lookbehind&touch=0', headers: { 'Sec-Fetch-Site' => 'cross-site' })

      expect(response).to have_http_status(:forbidden)
      expect(enqueued_reports).to be_empty
    end

    it 'takes a report from an old browser that does not say where it came from' do
      send_report('result=passed&touch=0')

      expect(response).to have_http_status(:no_content)
    end

    it 'takes a report the browser says came from the same page' do
      send_report('result=passed&touch=0', headers: { 'Sec-Fetch-Site' => 'same-origin' })

      expect(response).to have_http_status(:no_content)
    end
  end

  # The report is not the page load: the page has already loaded by the
  # time it is sent. Still, a report that cannot be queued answers the
  # same as one that was, and the failure is reported.
  it 'answers 204 and reports the error when the job cannot be queued' do
    allow(BrowserReportJob).to receive(:perform_later).and_raise(ActiveRecord::ConnectionNotEstablished, 'no database')
    allow(Rails.error).to receive(:report)

    send_report('result=passed&touch=0')

    expect(response).to have_http_status(:no_content)
    expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::ConnectionNotEstablished),
                                                       hash_including(handled: true))
  end
end
