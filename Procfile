web: bundle exec puma -C config/puma.rb
worker: env RAILS_DB_POOL=12 bin/jobs --mode async
release: bin/rake db:migrate
