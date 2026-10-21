# typed: true
# frozen_string_literal: true

# A resident's browser failed the browser check in index.html, and the
# resident saw the message that says the browser is too old or blocks
# cookies. Never raised: BrowserReportJob reports it through Rails.error,
# so Bugsnag emails the owner. The message names the browser and the
# failed tests.
class UnsupportedBrowserSeen < StandardError; end
