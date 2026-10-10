# frozen_string_literal: true

require 'rails_helper'

# Two people book the common house for the same evening at the same
# moment. Each request checks that the time is free before the other's
# booking is written, so both checks pass, and the database's EXCLUDE
# (common_house_reservations_no_overlap) refuses the second INSERT
# (#149). PostgreSQL reports that as an exclusion violation even at
# SERIALIZABLE, not as a serialization failure that RetryOnConflict would
# try again. The answer must be the 400 the model gives when it sees the
# other booking, not a 500.
#
# The first booking is written by a session of its own, opened with
# libpq, and held open until the request's INSERT waits for it. Without a
# test transaction, so that the two sessions see each other's commits.
# A libpq session does not get the SERIALIZABLE setting from
# config/database.yml, so it asks for it, and checks that the time is
# free before it writes, the way the model does. Both sessions then run
# as the app's do.
RSpec.describe 'two common house bookings for the same time at once' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let!(:resident) { create(:resident, community: community) }
  let(:token) { resident.keys.first.token }

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username],
               password: db[:password], dbname: db[:database])
  end

  # Polled rather than slept on: a fixed sleep would be either slow or
  # flaky. False when no INSERT waited within four seconds.
  def wait_for_blocked_insert(observer)
    200.times do
      waiting = observer.exec(
        'SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() ' \
        "AND wait_event_type = 'Lock' AND query LIKE 'INSERT INTO \"common_house_reservations\"%'"
      ).getvalue(0, 0).to_i
      return true if waiting.positive?

      sleep 0.02
    end
    false
  end

  it 'answers 400 in words, and keeps the booking that was written first' do
    first = open_session
    observer = open_session
    # 19:00 to 21:00 on April 15 in Los Angeles is 02:00 to 04:00 UTC on
    # April 16.
    first.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
    taken = first.exec(<<~SQL.squish).ntuples
      SELECT 1 FROM common_house_reservations
      WHERE start_date < '2026-04-16 04:00' AND end_date > start_date AND end_date > '2026-04-16 02:00'
    SQL
    first.exec_params(<<~SQL.squish, [community.id, resident.id])
      INSERT INTO common_house_reservations
        (community_id, resident_id, title, start_date, end_date, created_at, updated_at)
      VALUES ($1, $2, 'First', '2026-04-16 02:00', '2026-04-16 04:00', now(), now())
    SQL
    committer = Thread.new do
      waited = wait_for_blocked_insert(observer)
      first.exec('COMMIT')
      waited
    end

    post '/api/v1/common-house-reservations',
         params: { token: token, resident_id: resident.id, title: 'Second', start_year: 2026, start_month: 4,
                   start_day: 15, start_hours: 20, start_minutes: 0, end_hours: 22, end_minutes: 0 }

    expect(taken).to eq(0)
    expect(committer.value).to be(true)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq('message' => 'Time period is already taken')
    expect(CommonHouseReservation.pluck(:title)).to eq(['First'])
  ensure
    first&.close
    observer&.close
  end
end
