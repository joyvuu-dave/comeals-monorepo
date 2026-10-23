# frozen_string_literal: true

require 'rails_helper'

# After each deploy, the migrations production ran are deleted and
# db/production_schema_version.txt names the newest of them (its comment
# says how). db/structure.sql is then the only record of the schema.
RSpec.describe 'db/production_schema_version.txt' do
  let(:versions_on_disk) do
    Rails.root.glob('db/migrate/*.rb').map { |path| Integer(path.basename.to_s[/\A\d+/], 10) }
  end

  # The versions db/structure.sql records as run: its INSERT INTO
  # schema_migrations list, which is what a new database starts with.
  let(:versions_in_structure) do
    Rails.root.join('db/structure.sql').read[/INSERT INTO "schema_migrations" \(version\) VALUES\n(.*?);/m, 1]
         .scan(/'(\d+)'/).flatten.map { Integer(it, 10) }
  end

  def at_or_before_production(versions) = versions.select { |version| version <= PRODUCTION_SCHEMA_VERSION }

  # A file dated at or before that version is either one production ran,
  # which should have been deleted with the others, or a new migration
  # given an old date. spec/db/unrun_migrations_round_trip_spec.rb picks
  # the migrations production has not run by their date, so it would
  # leave the second kind out.
  it 'finds no migration file dated at or before the newest one production ran' do
    found = at_or_before_production(versions_on_disk)

    expect(found).to be_empty, "#{found.sort.join(', ')}: delete each one production ran, and date " \
                               "each one it has not run after #{PRODUCTION_SCHEMA_VERSION}"
  end

  # A real file would be a pending migration, which stops the suite
  # before any example runs, so the new file is a number here.
  it 'would find a migration dated before production\'s newest one, but not one dated after' do
    early = PRODUCTION_SCHEMA_VERSION - 1
    late = PRODUCTION_SCHEMA_VERSION + 1

    expect(at_or_before_production(versions_on_disk + [early, late])).to eq([early])
  end

  it 'names a migration that db/structure.sql records as run' do
    expect(versions_in_structure).to include(PRODUCTION_SCHEMA_VERSION)
  end

  # A migration production has not run must keep its file, or production
  # never runs it, while a new database built from db/structure.sql has
  # what it made. Only the ones up to production's newest may be deleted.
  it 'keeps the file of every migration that production has not run' do
    missing = versions_in_structure.reject { |version| version <= PRODUCTION_SCHEMA_VERSION } - versions_on_disk

    expect(missing).to be_empty, "#{missing.sort.join(', ')}: production has not run these, so their files must stay"
  end
end
