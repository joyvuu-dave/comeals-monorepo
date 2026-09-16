# frozen_string_literal: true

require Rails.root.join('lib/deploy_config_check')

namespace :deploy do
  desc 'Refuse the release when production lacks the config vars this code needs (Procfile release phase).'
  task verify_config: :environment do
    DeployConfigCheck.verify_config!
    puts 'deploy:verify_config: the config vars this release needs are set.'
  end

  desc 'Fail unless every Solid Queue process (supervisor, dispatcher, worker, scheduler) has a fresh heartbeat.'
  task verify_solid_queue: :environment do
    DeployConfigCheck.verify_processes!
    puts "deploy:verify_solid_queue: #{DeployConfigCheck::PROCESS_KINDS.join(', ')} are running."
  end
end
