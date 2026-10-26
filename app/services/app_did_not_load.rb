# typed: true
# frozen_string_literal: true

# The app's code did not load in a resident's browser, even after the
# page reloaded once, and the resident saw "Comeals could not load." with
# a Reload button (app/frontend/browser_check.js). Most likely a file the
# page asked for is not on the server: a page from before a deploy, or a
# network that dropped the file. Never raised: BrowserReportJob reports
# it through Rails.error, so Bugsnag emails the owner. The message names
# the browser and the file.
class AppDidNotLoad < StandardError; end
