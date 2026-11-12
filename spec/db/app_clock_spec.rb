# frozen_string_literal: true

require 'rails_helper'

# Every instant the app writes comes from Ruby's clock, Time.current
# (AGENTS.md, "Every wall-clock time is a community setting"), never from
# PostgreSQL's. travel_to and the seeded simulation's clock (challenge 31)
# decide Ruby's clock; the database's they cannot. And now() is the start
# of the transaction, so two writes in one transaction get the same time.
#
# The CURRENT_TIMESTAMP defaults of residents.keys_valid_since and
# common_house_logins.keys_valid_since in db/structure.sql stay, for rows
# written with raw SQL. Through the models, both columns are set again
# from Time.current right after the insert
# (revoke_all_sessions_if_password_changed); the model specs pin that.
RSpec.describe 'the database clock' do
  # The SQL functions and keywords that read PostgreSQL's clock. A dot
  # before one (Date.now(), performance.now()) is JavaScript, not SQL.
  let(:database_clock) do
    /(?<![.\w])(now\(\)|current_timestamp|current_date|current_time|localtimestamp|localtime|
     clock_timestamp|statement_timestamp|transaction_timestamp|timeofday)(?!\w)/ix
  end

  def uses(paths)
    paths.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?('#')

        "#{path.relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}" if line.match?(database_clock)
      end
    end
  end

  it "is not read by the app's Ruby code" do
    paths = Rails.root.glob('{app,lib}/**/*.rb').reject { it.to_s.include?('/app/frontend/') } +
            [Rails.root.join('db/seeds.rb')]
    expect(paths.size).to be > 100
    expect(uses(paths)).to eq([])
  end

  it 'finds each form, and skips comments and JavaScript' do
    Dir.mktmpdir do |dir|
      file = Pathname(dir).join('example.rb')
      File.write(file, <<~RUBY)
        execute('UPDATE t SET at = now()')
        execute('SELECT CURRENT_TIMESTAMP')
        execute("SELECT clock_timestamp()")
        # now() in a comment
        js = 'Date.now()'
        timestamps = :current_timestamps
      RUBY
      expect(uses([file]).map { it[/:(\d+):/, 1] }).to eq(%w[1 2 3])
    end
  end
end
