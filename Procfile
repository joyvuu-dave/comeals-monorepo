web: bundle exec puma -C config/puma.rb
worker: bin/jobs
release: bin/rake deploy:verify_config db:migrate
