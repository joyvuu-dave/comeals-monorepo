# frozen_string_literal: true

namespace :bugsnag do
  desc 'Send two deliberate test errors to Bugsnag, to prove reporting is connected.'
  task verify: :environment do
    if ENV['BUGSNAG_API_KEY'].blank?
      abort 'BUGSNAG_API_KEY is not set, so nothing would be sent. ' \
            'Run this on Heroku: heroku run rake bugsnag:verify'
    end

    unless Rails.env.production?
      abort "enabled_release_stages is production only, so nothing would be sent from #{Rails.env}."
    end

    # Two errors, because there are two paths and they can fail separately.
    # The first is what a crash looks like. The second goes through
    # Rails.error, which reaches Bugsnag only via BugsnagErrorSubscriber —
    # that is the path a retried transaction and a swallowed cache failure
    # will use, and the one that silently went nowhere before this existed.
    Bugsnag.notify(RuntimeError.new('bugsnag:verify — direct notify')) do |report|
      report.severity = 'info'
      report.add_tab(:verify, { path: 'Bugsnag.notify', task: 'bugsnag:verify' })
    end

    Rails.error.report(
      RuntimeError.new('bugsnag:verify — via Rails.error'),
      handled: true,
      severity: :info,
      context: { path: 'Rails.error', task: 'bugsnag:verify' }
    )

    puts 'Sent two test errors. Both should appear in the Bugsnag "comeals" project'
    puts 'under release stage production, within about a minute:'
    puts '  1. "bugsnag:verify — direct notify"    (the Rack/crash path)'
    puts '  2. "bugsnag:verify — via Rails.error"  (the handled-error path)'
    puts
    puts 'If only the first arrives, BugsnagErrorSubscriber is not subscribed.'
  end
end
