# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/squashed_migrations_check')

# The check the release phase runs before db:migrate. After a deploy, the
# migrations production ran are deleted from db/migrate/, and
# db/production_schema_version.txt names the newest of them. A database
# whose newest migration is older than that version needs migrations that
# no longer exist, so db:migrate runs nothing and reports success. On
# staging on 2026-10-24 that left the app running without the
# browser_counts table.
RSpec.describe SquashedMigrationsCheck do
  let(:file_text) { "# The newest migration production has run.\n#\n# More words.\n20261023140000\n" }

  describe '.squashed_version' do
    it 'reads the one line that is not a comment' do
      expect(described_class.squashed_version(file_text)).to eq(20_261_023_140_000)
    end

    it 'skips blank lines' do
      expect(described_class.squashed_version("# a comment\n\n   \n20261023140000\n\n")).to eq(20_261_023_140_000)
    end

    it 'refuses a file with no version' do
      expect { described_class.squashed_version("# only a comment\n") }
        .to raise_error(ArgumentError, 'db/production_schema_version.txt must hold one version, not []')
    end

    it 'refuses a file with two versions' do
      expect { described_class.squashed_version("20261016130000\n20261023140000\n") }
        .to raise_error(ArgumentError, /must hold one version, not \["20261016130000", "20261023140000"\]/)
    end

    it 'refuses a line that is not a number' do
      expect { described_class.squashed_version("2026-10-23\n") }.to raise_error(ArgumentError)
    end

    # Integer() without a base reads a leading 0 as octal, and 0x as hex.
    it 'reads the version in base 10' do
      expect(described_class.squashed_version("0010\n")).to eq(10)
    end

    it 'reads the file the deploy ships' do
      expect(described_class.squashed_version(Rails.root.join(described_class::VERSION_FILE).read))
        .to eq(PRODUCTION_SCHEMA_VERSION)
    end
  end

  describe '.recorded_versions' do
    let(:structure) do
      "CREATE TABLE a ();\n\nINSERT INTO \"schema_migrations\" (version) VALUES\n('20261023140000'),\n" \
        "('20170515164827');\n\n"
    end

    it 'reads the INSERT INTO schema_migrations list, as numbers' do
      expect(described_class.recorded_versions(structure)).to eq([20_261_023_140_000, 20_170_515_164_827])
    end

    it 'refuses a file with no list' do
      expect { described_class.recorded_versions("CREATE TABLE a ();\n") }
        .to raise_error(ArgumentError, 'db/structure.sql has no INSERT INTO schema_migrations list')
    end

    it 'reads the file the deploy ships, which names the version in db/production_schema_version.txt' do
      expect(described_class.recorded_versions(Rails.root.join('db/structure.sql').read))
        .to include(PRODUCTION_SCHEMA_VERSION)
    end
  end

  describe '.problem' do
    let(:squashed) { 20_261_023_140_000 }
    let(:recorded) { [20_170_515_164_827, 20_261_016_130_000, squashed] }

    def problem(database, recorded: self.recorded, tables: %w[meals schema_migrations])
      described_class.problem(database:, squashed:, recorded:, tables:)
    end

    it 'is satisfied when the database has run every deleted migration' do
      expect(problem(recorded)).to be_nil
    end

    # The newest version is the largest one, whatever order the list is in.
    it 'reads the newest version from a list in any order' do
      expect(problem(recorded.reverse)).to be_nil
    end

    # The file's own version is one of the deleted migrations too.
    it 'refuses a database that ran a newer migration but not the one the file names' do
      expect(problem(recorded - [squashed] + [20_261_030_000_000])).to match(/has not run 1 of .*: #{squashed}\./o)
    end

    it 'is satisfied when the database is ahead of the file' do
      expect(problem(recorded + [20_261_030_000_000])).to be_nil
    end

    # Rows production has that db/structure.sql does not list, such as
    # migrations from before the oldest one it keeps, are not a problem.
    it 'is satisfied when the database has versions db/structure.sql does not list' do
      expect(problem([20_150_101_000_000] + recorded)).to be_nil
    end

    # A migration that is still in db/migrate/ is db:migrate's job.
    it 'is satisfied when the database has not run a migration newer than the file' do
      expect(problem(recorded, recorded: recorded + [20_261_030_000_000])).to be_nil
    end

    # A brand new app: the database has no schema_migrations rows yet, and
    # db:migrate creates the table, as it always has. Its schema comes
    # from db/structure.sql, not from migrations.
    it 'is satisfied when the database has no tables and has run no migration' do
      expect(problem([], tables: [])).to be_nil
    end

    # No schema_migrations table: db:migrate would load db/structure.sql
    # over the tables. An empty one: db:migrate would do nothing.
    it 'refuses a database that has tables but no versions, and names the tables' do
      expect(problem([], tables: %w[schema_migrations meals])).to eq(
        'The database has tables (meals, schema_migrations) but no record of the migrations it has run: ' \
        'schema_migrations is missing or has no rows. So it is not a new database. With no schema_migrations ' \
        'table, db:migrate would load db/structure.sql over these tables, and with an empty one it would do ' \
        'nothing, so this code would run on a database it does not fit. Do one of these: restore a backup of ' \
        'this database, or, if this is a new app with no data to keep, empty its database (heroku pg:reset) ' \
        'and deploy again.'
      )
    end

    it 'names at most ten tables and counts the rest' do
      tables = (1..11).map { "table_#{it.to_s.rjust(2, '0')}" }

      expect(problem([], tables:)).to include("(#{tables.first(10).join(', ')} and 1 more)")
    end

    it 'names both versions and says what to do when the database is behind' do
      expect(problem([20_170_515_164_827, 20_261_016_130_000])).to eq(
        'The database is behind db/production_schema_version.txt. Its newest migration is 20261016130000, ' \
        'but the file says 20261023140000: the migrations up to 20261023140000 were deleted from db/migrate/ ' \
        'after production ran them. db:migrate cannot run a migration that has no file, so this code would ' \
        'run on a database without the tables and columns those migrations made. Do one of these: restore a ' \
        'backup taken after production ran migration 20261023140000, or deploy a commit whose ' \
        'db/production_schema_version.txt is 20261016130000 or older (that commit still has the migration files).'
      )
    end

    it 'refuses a database one version behind' do
      expect(problem([20_261_023_139_999])).to be_a(String)
    end

    it 'names the missing versions and says what to do when the database is missing an older one' do
      expect(problem([20_170_515_164_827, squashed])).to eq(
        'The database has not run 1 of the migrations that were deleted from db/migrate/ after production ran ' \
        'them: 20261016130000. Its newest migration is not older than db/production_schema_version.txt ' \
        '(20261023140000), but db/structure.sql lists these as run, and they are not in schema_migrations. ' \
        'db:migrate cannot run a migration that has no file, so this code would run on a database without the ' \
        'tables and columns those migrations made. Do one of these: restore a backup taken after production ' \
        'ran migration 20261023140000, or deploy a commit whose db/production_schema_version.txt is older than ' \
        '20261016130000 (that commit still has the migration files).'
      )
    end

    it 'names at most ten missing versions, oldest first, and counts the rest' do
      older = (1..12).map { 20_200_101_000_000 + it }

      expect(problem([squashed], recorded: older.reverse + [squashed]))
        .to include("them: #{older.first(10).join(', ')} and 2 more. ")
        .and include('is older than 20200101000001 ')
    end
  end

  describe '.database_versions' do
    let(:connection) { ActiveRecord::Base.connection }

    it 'is every version in schema_migrations, as numbers' do
      expect(described_class.database_versions).to match_array(
        described_class.recorded_versions(Rails.root.join('db/structure.sql').read)
      )
    end

    # Numbers, not text, so a short version cannot sort after a long one.
    it 'reads the versions as numbers' do
      connection.execute('DELETE FROM schema_migrations')
      connection.execute("INSERT INTO schema_migrations (version) VALUES ('9'), ('20261016130000')")

      expect(described_class.database_versions).to contain_exactly(9, 20_261_016_130_000)
    end

    it 'is empty when schema_migrations has no rows' do
      connection.execute('DELETE FROM schema_migrations')

      expect(described_class.database_versions).to eq([])
    end

    # Postgres rolls back DDL with the example's transaction.
    it 'is empty when there is no schema_migrations table' do
      connection.execute('ALTER TABLE schema_migrations RENAME TO schema_migrations_hidden')

      expect(described_class.database_versions).to eq([])
    end
  end

  describe '.verify!' do
    let(:connection) { ActiveRecord::Base.connection }

    it 'passes on a database that has run every migration, and returns its newest version' do
      expect(described_class.verify!).to eq(PRODUCTION_SCHEMA_VERSION)
    end

    it 'raises with the problem when the database is behind the file' do
      connection.execute("DELETE FROM schema_migrations WHERE version::bigint >= #{PRODUCTION_SCHEMA_VERSION}")
      expect { described_class.verify! }.to raise_error(
        described_class::DatabaseBehind,
        described_class.problem(database: described_class.database_versions, squashed: PRODUCTION_SCHEMA_VERSION,
                                recorded: described_class.recorded_versions(Rails.root.join('db/structure.sql').read),
                                tables: connection.tables)
      )
    end

    # A database that has run the newest deleted migration but not an
    # older one: a backup restored and then migrated by code that skipped
    # one, or a row deleted by hand. Its newest version is not behind, but
    # the tables of the missing migration are not there (#248, item 3).
    it 'raises when the database is missing a deleted migration older than its newest' do
      oldest = connection.select_value('SELECT min(version::bigint) FROM schema_migrations')
      connection.execute("DELETE FROM schema_migrations WHERE version::bigint = #{oldest}")

      expect { described_class.verify! }.to raise_error(described_class::DatabaseBehind, /#{oldest}/)
    end

    # The test database has every table, so with no schema_migrations
    # table it is not new. A new database passes: spec/config/procfile_spec.rb
    # runs the release command on one.
    it 'raises on a database that has tables but no schema_migrations table' do
      connection.execute('ALTER TABLE schema_migrations RENAME TO schema_migrations_hidden')

      expect { described_class.verify! }
        .to raise_error(described_class::DatabaseBehind, /but no record of the migrations it has run/)
    end

    it 'returns nil for a database with no tables and no versions' do
      allow(described_class).to receive(:database_versions).and_return([])
      allow(connection).to receive(:tables).and_return([])

      expect(described_class.verify!).to be_nil
    end
  end
end
