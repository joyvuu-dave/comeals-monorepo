# frozen_string_literal: true

require 'rails_helper'

# bin/test-integration runs a real server against this worktree's test
# database, so the suite's rows really commit, and its cleanup is what
# empties the database for the next RSpec run and the next integration
# run. It named a few tables and let CASCADE follow the foreign keys from
# them, so a table no foreign key reaches kept its rows: request_keys did,
# and the next run's guest removals were answered from them (#295). Now
# it runs bin/lib/empty_test_database.sql, which empties every table but
# Rails' own two. This runs that file inside the example's transaction.
RSpec.describe 'bin/test-integration cleanup' do
  let(:sql) { Rails.root.join('bin/lib/empty_test_database.sql').read }

  it 'empties every table except schema_migrations and ar_internal_metadata' do
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL.squish)
      INSERT INTO request_keys (sender, key, request_sha256, status, body, created_at)
      VALUES ('Resident:1', 'a key only this example writes', '#{'0' * 64}', 200, '{}', now())
    SQL
    conn.execute("INSERT INTO throttle_counts (key, count, expires_at) VALUES ('a', 1, now() + interval '1 hour')")

    expect(Rails.root.join('bin/test-integration').read).to include('-f bin/lib/empty_test_database.sql')
    conn.execute(sql)

    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    left = tables.select { |table| conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})") }
    expect(left).to eq([])
  end
end
