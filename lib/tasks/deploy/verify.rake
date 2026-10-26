# frozen_string_literal: true

require Rails.root.join('lib/solid_queue_check')
require Rails.root.join('lib/squashed_migrations_check')

namespace :deploy do
  desc 'Fail unless every Solid Queue process (supervisor, dispatcher, worker, scheduler) has a fresh heartbeat.'
  task verify_solid_queue: :environment do
    SolidQueueCheck.verify_processes!
    puts "deploy:verify_solid_queue: #{SolidQueueCheck::PROCESS_KINDS.join(', ')} are running."
  end

  desc 'Queue a recurring task the way the scheduler does, and fail unless the worker runs it within two minutes.'
  task verify_recurring_job: :environment do
    puts "deploy:verify_recurring_job: #{SolidQueueCheck.verify_recurring_run!}."
  end

  # The release phase runs this before db:migrate (Procfile), so a
  # database restored from a backup older than the deleted migrations is
  # refused instead of migrated with nothing (lib/squashed_migrations_check.rb).
  desc 'Fail when the database is behind db/production_schema_version.txt, whose migrations were deleted.'
  task verify_schema_version: :environment do
    newest = SquashedMigrationsCheck.verify!
    if newest
      puts 'deploy:verify_schema_version: the database has run every deleted migration, the ones ' \
           "#{SquashedMigrationsCheck::STRUCTURE_FILE} lists up to #{SquashedMigrationsCheck::VERSION_FILE}. " \
           "Its newest migration is #{newest}."
    else
      puts 'deploy:verify_schema_version: the database has no tables, so it is new. ' \
           "db:migrate builds it from #{SquashedMigrationsCheck::STRUCTURE_FILE}."
    end
  end
end
