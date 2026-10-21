# typed: true
# frozen_string_literal: true

module Api
  module V1
    # POST /api/v1/browser-reports: the one report the browser check in
    # index.html (app/frontend/browser_check.js) sends per page load. No
    # login, because the check runs before anyone signs in.
    #
    # The request only checks the report and queues BrowserReportJob,
    # which does the rest outside the request. An alert sent from here
    # would carry the request's IP address: Bugsnag's Rack middleware adds
    # it to anything reported during a request.
    #
    # Rack::Attack limits how often one IP address can send reports, and
    # alerts much more tightly (config/initializers/rack_attack.rb).
    class BrowserReportsController < ApiController
      # The check sends no body. A body over a kilobyte is refused unread.
      MAX_BODY = 1.kilobyte

      def create
        return head(:content_too_large) if body_too_large?
        return head(:forbidden) if from_another_site?

        # The query string only, as the check sends it. Rack::Attack's alert
        # limit reads the result from there, so a result in a form body
        # must not count.
        report = BrowserReport.new(ActionController::Parameters.new(request.query_parameters), request.user_agent)
        queue(report) unless report.browser.bot?
        head :no_content
      rescue BrowserReport::Invalid => e
        render json: { message: "This is not a browser check report: #{e.message}." }, status: :bad_request
      end

      private

      # Reads at most one byte more than the limit, so a large body is
      # never read into memory, whatever its Content-Length says.
      def body_too_large?
        body = request.body.read(MAX_BODY + 1).to_s
        body.bytesize > MAX_BODY
      end

      # A browser says, in Sec-Fetch-Site, which site a request came from.
      # The check's report comes from the app's own page, so it says
      # same-origin. An old browser does not send the header at all.
      def from_another_site?
        site = request.headers['Sec-Fetch-Site']
        site.present? && site != 'same-origin'
      end

      # The page has loaded by the time its report arrives, so a report
      # that cannot be queued changes nothing for the person. It answers
      # the same, and the failure is reported.
      def queue(report)
        BrowserReportJob.perform_later(**report.job_arguments)
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { browser_report: report.result })
      end
    end
  end
end
