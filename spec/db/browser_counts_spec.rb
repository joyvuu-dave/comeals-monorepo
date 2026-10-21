# frozen_string_literal: true

require 'rails_helper'

# browser_counts holds its rules in the database too, for a write that
# skips the model. And two page loads of the same kind of browser at the
# same moment write the same row: at SERIALIZABLE the second one is
# refused, and the count must still end up right.
RSpec.describe 'browser_counts table' do
  def insert(**changes)
    row = { date: '2026-10-21', browser: 'Safari', major: 18, os: 'iOS', device: 'phone',
            result: 'passed', count: 1 }.merge(changes)
    values = row.values.map { |value| ActiveRecord::Base.connection.quote(value) }
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO browser_counts (#{row.keys.join(', ')}, created_at, updated_at)
      VALUES (#{values.join(', ')}, now(), now())
    SQL
  end

  it 'takes a good row' do
    expect { insert }.to change(BrowserCount, :count).by(1)
  end

  {
    'a device that is not one of the four' => [{ device: 'watch' }, /browser_counts_device_is_known/],
    'a result that is not one of the three' => [{ result: 'maybe' }, /browser_counts_result_is_known/],
    'a count below one' => [{ count: 0 }, /browser_counts_count_is_positive/],
    'a version of zero' => [{ major: 0 }, /browser_counts_major_is_positive/],
    'an empty browser name' => [{ browser: '' }, /browser_counts_browser_length/],
    'a browser name over 60 characters' => [{ browser: 'x' * 61 }, /browser_counts_browser_length/],
    'an empty system name' => [{ os: '' }, /browser_counts_os_length/]
  }.each do |name, (change, constraint)|
    it "refuses #{name}" do
      expect { insert(**change) }.to raise_error(ActiveRecord::StatementInvalid, constraint)
    end
  end

  it 'refuses a missing date, browser, system, device, result or count' do
    %i[date browser os device result count].each do |column|
      expect { ActiveRecord::Base.transaction(requires_new: true) { insert(column => nil) } }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  # NULL is never equal to NULL in a plain unique index, so two rows with
  # no version would both go in, and the count would split.
  it 'refuses a second row for the same day and browser, with no version too' do
    insert(major: nil)

    expect { insert(major: nil) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The first write is held open on a session of its own, the way a
  # second page load's job finds it. The second write waits for the
  # first's row, and when the first commits, PostgreSQL refuses the
  # second at SERIALIZABLE: the row it must update is not in its snapshot.
  describe 'two page loads of the same browser at the same moment' do
    include_context 'with no test transaction'

    let(:key) do
      { date: Date.new(2026, 10, 21), browser: 'Safari', major: 18, os: 'iOS', device: 'phone', result: 'passed' }
    end
    let(:report) { { **key, tests: [], error: nil, user_agent: 'Safari' } }

    before { allow(Rails.error).to receive(:report) }

    def open_session
      db = ActiveRecord::Base.connection_db_config.configuration_hash
      PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
    end

    # The first page load's write, not yet committed.
    def first_write_open
      session = open_session
      session.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
      session.exec(<<~SQL.squish)
        INSERT INTO browser_counts (date, browser, major, os, device, result, count, created_at, updated_at)
        VALUES ('2026-10-21', 'Safari', 18, 'iOS', 'phone', 'passed', 1, now(), now())
        ON CONFLICT (date, browser, (COALESCE(major, 0)), os, device, result)
        DO UPDATE SET count = browser_counts.count + 1
      SQL
      session
    end

    # Runs the block on a connection of its own, in a thread, and returns
    # the thread once the block waits for the first write's row lock.
    def second_write_waiting(&)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection(&)
        :ok
      rescue StandardError => e
        e.class.name
      end
      Timeout.timeout(10) { sleep 0.01 until waiting_for_a_lock? }
      thread
    end

    # Other worktrees share the PostgreSQL server, so only this database's
    # sessions are looked at.
    def waiting_for_a_lock?
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).positive?
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
      SQL
    end

    it 'refuses the second write at SERIALIZABLE, so the count needs a retry' do
      first = first_write_open
      second = second_write_waiting { BrowserCount.add_one!(**key) }
      first.exec('COMMIT')

      expect(second.value).to eq('ActiveRecord::SerializationFailure')
    ensure
      first&.close
    end

    it 'counts both, because the job tries the refused write again' do
      first = first_write_open
      second = second_write_waiting { BrowserReportJob.perform_now(**report) }
      first.exec('COMMIT')

      expect(second.value).to eq(:ok)
      expect(BrowserCount.sole.count).to eq(2)
    ensure
      first&.close
    end
  end
end
