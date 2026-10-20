web: bundle exec puma -C config/puma.rb
worker: env RAILS_DB_POOL=3 bin/jobs
release: bin/rake db:migrate
