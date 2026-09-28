# frozen_string_literal: true

require 'rails_helper'

# StorableTime writes PostgreSQL's limits down by hand. This asks the
# database about each end and one microsecond past it, so a wrong limit
# fails here and not as a 500.
RSpec.describe StorableTime do
  let(:microsecond) { Rational(1, 1_000_000) }

  # Whether PostgreSQL takes the time as a timestamp, the column type of
  # every start_date and end_date. A refusal aborts the statement, so it
  # runs in a savepoint the example can go on after.
  def database_takes?(time)
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(['SELECT ?::timestamp', time]))
    end
    true
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.cause.is_a?(PG::DatetimeFieldOverflow)

    false
  end

  def answers(times)
    times.transform_values { |time| { storable: described_class.timestamp?(time), database: database_takes?(time) } }
  end

  it 'agrees with the database at both ends, to the microsecond' do
    first = described_class::TIMESTAMPS.begin
    past_last = described_class::TIMESTAMPS.end

    yes = { storable: true, database: true }
    no = { storable: false, database: false }
    expect(answers('before the first' => first - microsecond, 'the first' => first,
                   'the last' => past_last - microsecond, 'after the last' => past_last))
      .to eq('before the first' => no, 'the first' => yes, 'the last' => yes, 'after the last' => no)
  end

  it 'names the first and the last instant in UTC' do
    expect(described_class::TIMESTAMPS.begin).to eq(Time.utc(-4713, 11, 24))
    expect(described_class::TIMESTAMPS.end - microsecond)
      .to eq(Time.utc(294_276, 12, 31, 23, 59, 59 + (999_999 * microsecond)))
  end

  # A time in a zone is compared as an instant: 16:00 on the last day in
  # Los Angeles is already the next year in UTC.
  it 'reads a time in another zone as the instant it is' do
    Time.use_zone('America/Los_Angeles') do
      last_minute = Time.zone.local(294_276, 12, 31, 15, 59)
      next_minute = Time.zone.local(294_276, 12, 31, 16, 0)

      expect(answers('15:59' => last_minute, '16:00' => next_minute))
        .to eq('15:59' => { storable: true, database: true }, '16:00' => { storable: false, database: false })
    end
  end
end
