# frozen_string_literal: true

require 'rails_helper'

# spec/support/server_notices.rb records what PostgreSQL sends that is not
# an error, on every connection the suite opens, and fails an example that
# did not expect it.
RSpec.describe ServerNotices do
  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  it 'records a warning on a raw session, with nothing printed' do
    session = open_session
    notices = capture_server_notices { session.exec('ROLLBACK') }

    expect(notices).to eq([ServerNotices::REFUSED_COMMIT])
  ensure
    session&.close
  end

  it "records a warning on the app's own connection" do
    connection = ActiveRecord::Base.connection
    notices = capture_server_notices { connection.execute("DO $$ BEGIN RAISE WARNING 'from the app'; END $$") }

    expect(notices).to eq(["WARNING:  from the app\n"])
  end

  it 'counts one refused commit with expect_one_refused_commit' do
    session = open_session
    expect_one_refused_commit { session.exec('ROLLBACK') }
  ensure
    session&.close
  end

  it 'fails the check on a notice no pattern allows, and names it' do
    expect { described_class.check!(["WARNING:  odd\n"], allowed: [], where: 'that this example did not expect') }
      .to raise_error(ServerNotices::Unexpected,
                      /sent 1 notice\(s\) that this example did not expect:\n  WARNING:  odd\n/)
  end

  it 'passes the check on a notice a pattern allows' do
    expect { described_class.check!([ServerNotices::REFUSED_COMMIT], allowed: [ServerNotices::REFUSED_COMMIT], where: 'x') }
      .not_to raise_error
  end

  it 'leaves a notice outside capture_server_notices for the check after the example' do
    session = open_session
    session.exec('ROLLBACK')

    expect(described_class.take).to eq([ServerNotices::REFUSED_COMMIT])
  ensure
    session&.close
  end
end
