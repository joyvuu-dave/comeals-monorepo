# frozen_string_literal: true

require 'rails_helper'

# Every schema migration that production has not run yet (newer than
# PRODUCTION_SCHEMA_VERSION, spec/simplecov_profile.rb) runs down, newest first,
# and then up again, oldest first, inside the example's transaction. The
# schema after that must be the schema before it, object for object. So
# each down undoes exactly what its up does, and each up still runs on
# the schema the one before it leaves. Postgres rolls all of it back with
# the example.
#
# The data migrations (the ones that turn off the DDL transaction) are left
# out here: their down changes no schema, and each has its own spec in
# spec/db/ that runs it on rows.
RSpec.describe 'the migrations production has not run' do
  let(:connection) { ActiveRecord::Base.connection }

  # Each file is loaded with require, as the other migration specs load
  # theirs, and never with Rails' own loader, which uses load. Loading a
  # file a second time starts its coverage count again from zero, so a
  # second load would throw away what the first run counted.
  let(:schema_migrations) do
    connection.pool.migration_context.migrations
              .select { |proxy| proxy.version > PRODUCTION_SCHEMA_VERSION }
              .map do |proxy|
                require File.expand_path(proxy.filename, Rails.root)
                proxy.name.constantize.new(proxy.name, proxy.version)
              end
              .reject(&:disable_ddl_transaction)
  end

  # The files themselves say which migrations production has not run, and
  # which of those are data migrations. Counting from the files, and not
  # from a number written here, keeps this right after each deploy moves
  # db/production_schema_version.txt and deletes the files it ran.
  let(:unrun_schema_migration_files) do
    Rails.root.glob('db/migrate/*.rb')
         .select { |path| Integer(path.basename.to_s[/\A\d+/], 10) > PRODUCTION_SCHEMA_VERSION }
         .reject { |path| path.read.include?('disable_ddl_transaction!') }
  end

  # Everything a migration can make in the public schema, each object as
  # Postgres prints its definition.
  def schema
    {
      columns: connection.select_rows(<<~SQL.squish),
        SELECT table_name, column_name, data_type, is_nullable, column_default, numeric_precision, numeric_scale
        FROM information_schema.columns WHERE table_schema = 'public'
        ORDER BY table_name, column_name
      SQL
      constraints: connection.select_rows(<<~SQL.squish).map { |row| row.dup.tap { |r| r[2] = same_meaning(r[2]) } },
        SELECT conrelid::regclass::text, conname, pg_get_constraintdef(oid), condeferrable, condeferred, convalidated
        FROM pg_constraint WHERE connamespace = 'public'::regnamespace
        ORDER BY 1, 2
      SQL
      indexes: connection.select_rows(<<~SQL.squish),
        SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1, 2
      SQL
      triggers: connection.select_rows(<<~SQL.squish),
        SELECT tgrelid::regclass::text, tgname, pg_get_triggerdef(oid)
        FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2
      SQL
      functions: connection.select_rows(<<~SQL.squish),
        SELECT proname, pg_get_function_identity_arguments(oid), pg_get_functiondef(oid)
        FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
        ORDER BY 1, 2
      SQL
      extensions: connection.select_values('SELECT extname FROM pg_extension ORDER BY 1')
    }
  end

  # Postgres prints a CHECK on a string column with the casts where it put
  # them. A CHECK made from a migration's own text, such as
  #   status IN ('paid', 'let_go', 'none')
  # puts them in other places than the same CHECK read back from
  # db/structure.sql, which the test database is built from, though both
  # mean the same thing. Without the casts and the brackets the two print
  # the same.
  def same_meaning(definition)
    definition.gsub(/::(character varying|text)(\[\])?/, '').delete('() ')
  end

  def run_each(direction, migrations)
    $stdout = StringIO.new
    migrations.each { |migration| migration.migrate(direction) }
  ensure
    $stdout = STDOUT
  end

  # strong_migrations refuses to validate a constraint while this session
  # holds a lock that blocks writes. A real migration starts in a new
  # transaction with no lock. Here every migration runs in one transaction,
  # so the downs before it hold those locks, and the check would refuse a
  # validation that a real deploy runs. Every other check still runs.
  before do
    allow_any_instance_of(StrongMigrations::Adapters::PostgreSQLAdapter) # rubocop:disable RSpec/AnyInstance
      .to receive(:writes_blocked?).and_return(false)
  end

  after do
    connection.schema_cache.clear!
    ActiveRecord::Base.descendants.each(&:reset_column_information)
  end

  it 'covers every schema migration after production\'s newest one' do
    expect(schema_migrations.map(&:version)).to all(be > PRODUCTION_SCHEMA_VERSION)
    expect(schema_migrations.size).to eq(unrun_schema_migration_files.size)
  end

  it 'leaves the schema as it was after running down and up again' do
    skip 'production has run every schema migration' if schema_migrations.empty?

    before = schema

    run_each(:down, schema_migrations.reverse)
    rolled_back = schema
    run_each(:up, schema_migrations)

    expect(rolled_back).not_to eq(before)
    expect(schema).to eq(before)
  end
end
