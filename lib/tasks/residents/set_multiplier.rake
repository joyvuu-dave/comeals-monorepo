# frozen_string_literal: true

namespace :residents do
  desc "Automatically set residents' multiplier based on their age."
  task set_multiplier: :environment do
    # The scheduled version is SetMultipliersJob (config/recurring.yml).
    SetMultipliersJob.perform_now
  end
end
