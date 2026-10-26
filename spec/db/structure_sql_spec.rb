# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# db/structure.sql is what a new database is built from: by db:prepare on a
# laptop, and on a new Heroku app by the release phase's db:migrate.
RSpec.describe 'db/structure.sql' do
  let(:structure) { Rails.root.join('db/structure.sql').read }

  # On Heroku the extensions belong to rdsadmin, and the app's database
  # user is not a superuser. A COMMENT ON EXTENSION needs the extension's
  # owner, so loading the file stopped at the first one: "must be owner of
  # extension pg_stat_statements", with no table made. Tested on a fresh
  # Essential-0 database (PostgreSQL 18.4) on 2026-10-26: without these
  # statements the whole file loads (#248).
  it 'holds no COMMENT ON EXTENSION' do
    expect(structure.scan(/^COMMENT ON EXTENSION .*$/)).to eq([])
  end

  it 'still creates the extensions' do
    expect(structure).to include('CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;',
                                 'CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;',
                                 'CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;')
  end

  # The test database is built from db/structure.sql, so a dump of it
  # must give the same file back. This is the dump db:migrate writes, so
  # it shows that every dump leaves the COMMENT ON EXTENSION statements
  # out (lib/structure_dump_cleanup.rb).
  it 'is what a dump of the test database writes' do
    Dir.mktmpdir('structure-dump') do |dir|
      dump = File.join(dir, 'structure.sql')
      output, status = Open3.capture2e({ 'RAILS_ENV' => 'test', 'RUBYOPT' => nil, 'SCHEMA' => dump },
                                       'bin/rails', 'db:schema:dump', chdir: Rails.root.to_s)

      expect(status).to be_success, output
      expect(File.read(dump)).to eq(structure)
    end
  end
end
