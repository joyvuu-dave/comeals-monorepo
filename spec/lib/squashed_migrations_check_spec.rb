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

  describe '.problem' do
    it 'is satisfied when the database has run the newest deleted migration' do
      expect(described_class.problem(newest: 20_261_023_140_000, squashed: 20_261_023_140_000)).to be_nil
    end

    it 'is satisfied when the database is ahead of the file' do
      expect(described_class.problem(newest: 20_261_030_000_000, squashed: 20_261_023_140_000)).to be_nil
    end

    # A brand new app: the database has no schema_migrations rows yet, and
    # db:migrate creates the table, as it always has. Its schema comes
    # from db/structure.sql, not from migrations.
    it 'is satisfied when the database has run no migration at all' do
      expect(described_class.problem(newest: nil, squashed: 20_261_023_140_000)).to be_nil
    end

    it 'names both versions and says what to do when the database is behind' do
      expect(described_class.problem(newest: 20_261_016_130_000, squashed: 20_261_023_140_000)).to eq(
        'The database is behind db/production_schema_version.txt. Its newest migration is 20261016130000, ' \
        'but the file says 20261023140000: the migrations up to 20261023140000 were deleted from db/migrate/ ' \
        'after production ran them. db:migrate cannot run a migration that has no file, so this code would ' \
        'run on a database without the tables and columns those migrations made. Do one of these: restore a ' \
        'backup taken after production ran migration 20261023140000, or deploy a commit whose ' \
        'db/production_schema_version.txt is 20261016130000 or older (that commit still has the migration files).'
      )
    end

    it 'refuses a database one version behind' do
      expect(described_class.problem(newest: 20_261_023_139_999, squashed: 20_261_023_140_000)).to be_a(String)
    end
  end

  describe '.newest_version' do
    let(:connection) { ActiveRecord::Base.connection }

    it 'is the newest version in schema_migrations' do
      expect(described_class.newest_version).to eq(PRODUCTION_SCHEMA_VERSION)
    end

    # Compared as numbers, not as text, so a short version cannot sort
    # after a long one.
    it 'compares the versions as numbers' do
      connection.execute('DELETE FROM schema_migrations')
      connection.execute("INSERT INTO schema_migrations (version) VALUES ('9'), ('20261016130000')")

      expect(described_class.newest_version).to eq(20_261_016_130_000)
    end

    it 'is nil when schema_migrations has no rows' do
      connection.execute('DELETE FROM schema_migrations')

      expect(described_class.newest_version).to be_nil
    end

    # Postgres rolls back DDL with the example's transaction.
    it 'is nil when there is no schema_migrations table' do
      connection.execute('ALTER TABLE schema_migrations RENAME TO schema_migrations_hidden')

      expect(described_class.newest_version).to be_nil
    end
  end

  describe '.verify!' do
    let(:connection) { ActiveRecord::Base.connection }

    it 'passes on a database that has run every migration, and returns its newest version' do
      expect(described_class.verify!).to eq(PRODUCTION_SCHEMA_VERSION)
    end

    it 'raises with the problem when the database is behind the file' do
      connection.execute("DELETE FROM schema_migrations WHERE version::bigint >= #{PRODUCTION_SCHEMA_VERSION}")
      newest = described_class.newest_version

      expect { described_class.verify! }.to raise_error(
        described_class::DatabaseBehind,
        described_class.problem(newest:, squashed: PRODUCTION_SCHEMA_VERSION)
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

    it 'passes on a database with no schema_migrations table, and returns nil' do
      connection.execute('ALTER TABLE schema_migrations RENAME TO schema_migrations_hidden')

      expect(described_class.verify!).to be_nil
    end
  end
end
