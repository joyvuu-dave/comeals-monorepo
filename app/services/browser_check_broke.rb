# typed: true
# frozen_string_literal: true

# The browser check in index.html threw an error of its own. The app
# started anyway, because a mistake in the check must not turn away a
# working browser. Never raised: BrowserReportJob reports it through
# Rails.error, so Bugsnag emails the owner. The message holds the
# browser's error.
class BrowserCheckBroke < StandardError; end
