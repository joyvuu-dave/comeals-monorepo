# frozen_string_literal: true

require Rails.root.join('lib/solid_queue_check')

namespace :deploy do
  desc 'Fail unless every Solid Queue process (supervisor, dispatcher, worker, scheduler) has a fresh heartbeat.'
  task verify_solid_queue: :environment do
    SolidQueueCheck.verify_processes!
    puts "deploy:verify_solid_queue: #{SolidQueueCheck::PROCESS_KINDS.join(', ')} are running."
  end
end
