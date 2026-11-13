# frozen_string_literal: true

# The fault suite (challenge 30). bin/faults runs it. It is the
# real-server storm (rake test:storm) with things breaking while it runs:
#
#   - its own PostgreSQL (Faults::Server, under tmp/faults), never the
#     server the worktrees and the development database share;
#   - every database connection, from the server and from this process,
#     goes through a proxy (Faults::Proxy) that the driver cuts, or takes
#     down for a moment;
#   - the driver restarts that PostgreSQL, and moves the server's clock
#     (Faults::Clock) forward and back;
#   - some answers to writes are lost, and the phone sends the same
#     request again (Faults::LossyTransport).
#
# Afterwards: the storm's checks (every meal's ledger, settled meals
# untouched, caps, ledger:verify, the calendar cache), and Faults::Report:
# a write saved but answered with an error when sent again, and a write
# saved twice.
#
#   FAULTS_SECONDS  how long (default 30)
#   FAULTS_CLIENTS  how many phones (default 16)
#   FAULTS_SEED     the seed for the requests and the faults (default 1)
#   FAULTS_LOSE     the chance an answer to a write is lost (default 0.05)
#   FAULTS_EVERY    seconds between faults (default 2)
namespace :test do
  desc 'Run the storm while connections drop, PostgreSQL restarts and the clock moves; check the books after'
  task faults: :environment do
    abort 'Must run in the test environment' unless Rails.env.test?
    Rails.root.glob('spec/support/storm/*.rb').each { |f| require f }
    Rails.root.glob('spec/support/faults/*.rb').each { |f| require f }
    require Rails.root.join('spec/support/random_ledger')

    # The run itself, and what it checks: spec/support/faults/session.rb.
    abort unless Faults::Session.new(ENV, out: $stdout).call
  end
end
