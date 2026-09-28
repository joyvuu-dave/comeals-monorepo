# frozen_string_literal: true

require 'rails_helper'

# StorableTime writes PostgreSQL's limits down by hand. This asks the
# database about each end and one step past it, so a wrong limit fails
# here and not as a 500.
RSpec.describe StorableTime do
  let(:microsecond) { Rational(1, 1_000_000) }

  # Whether PostgreSQL takes the value as a column of this type. Rails
  # quotes it the way it does on a save. A refusal aborts the statement,
  # so it runs in a savepoint the example can go on after.
  def database_takes?(value, type)
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT ?::#{type}", value]))
    end
    true
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.cause.is_a?(PG::DatetimeFieldOverflow)

    false
  end

  def answers(times)
    times.transform_values do |time|
      { storable: described_class.timestamp?(time), database: database_takes?(time, 'timestamp') }
    end
  end

  def date_answers(days)
    days.transform_values { |day| { storable: described_class.date?(day), database: database_takes?(day, 'date') } }
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

  describe '.date?' do
    let(:yes) { { storable: true, database: true } }
    let(:no) { { storable: false, database: false } }

    it 'agrees with the database at both ends, to the day' do
      first = described_class::DATES.begin
      last = described_class::DATES.end

      expect(date_answers('before the first' => first - 1, 'the first' => first,
                          'the last' => last, 'after the last' => last + 1))
        .to eq('before the first' => no, 'the first' => yes, 'the last' => yes, 'after the last' => no)
    end

    it 'names the first and the last day' do
      expect([described_class::DATES.begin, described_class::DATES.end].map(&:iso8601))
        .to eq(%w[-4713-11-24 5874897-12-31])
    end

    # Ruby's Date counts days before October 15, 1582 in the Julian
    # calendar unless told otherwise, and Rails sends the year, month and
    # day as written. February 29, 1500 is a Julian leap day the
    # Gregorian calendar does not have; the Julian November 23, 4714 BC
    # is a day inside the range, but written as a Gregorian date it is
    # outside it.
    it 'reads the year, month and day as written, in the Gregorian calendar' do
      expect(date_answers('Julian February 29, 1500' => Date.new(1500, 2, 29),
                          'February 29, 1600' => Date.new(1600, 2, 29),
                          'Julian November 23, 4714 BC' => Date.new(-4713, 11, 23),
                          'Julian November 24, 4714 BC' => Date.new(-4713, 11, 24)))
        .to eq('Julian February 29, 1500' => no, 'February 29, 1600' => yes,
               'Julian November 23, 4714 BC' => no, 'Julian November 24, 4714 BC' => yes)
    end
  end
end
