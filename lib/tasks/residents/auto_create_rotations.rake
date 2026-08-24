# frozen_string_literal: true

namespace :community do
  desc 'Automatically create rotations so we always have 6 mo worth.'
  task create_rotations: :environment do
    # The scheduled version is EnsureRotationsJob (config/recurring.yml).
    EnsureRotationsJob.perform_now
  end
end
