# frozen_string_literal: true

require 'rails_helper'

# Under SERIALIZABLE, PostgreSQL can refuse a transaction at its COMMIT,
# not only at a statement: two transactions each read a row the other
# writes, and the second to commit is refused. A refused COMMIT ends the
# transaction. Rails then sends a ROLLBACK anyway
# (TransactionManager#within_new_transaction rolls back whenever
# commit_transaction raises), and PostgreSQL answers that with
# "WARNING:  there is no transaction in progress". The request storm
# prints that warning about 60 times a run, one for each COMMIT it gets
# refused (#164). This pins what the warning means: nothing was saved,
# the caller sees the conflict, and RetryOnConflict tries again.
RSpec.describe 'a COMMIT that PostgreSQL refuses' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let!(:first) { create(:meal, community: community, date: Date.new(2026, 3, 1), description: 'first') }
  let!(:second) { create(:meal, community: community, date: Date.new(2026, 3, 5), description: 'second') }

  def open_session
    db = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: db[:host], port: db[:port], user: db[:username], password: db[:password], dbname: db[:database])
  end

  # Another SERIALIZABLE transaction: it reads both rows, writes the
  # first, and commits. Run inside the app's transaction, after the app
  # read both rows and before it writes the second, it makes the app's
  # COMMIT the one PostgreSQL refuses.
  def cross_with(other)
    other.exec('BEGIN ISOLATION LEVEL SERIALIZABLE')
    other.exec_params('SELECT description FROM meals WHERE id IN ($1, $2)', [first.id, second.id])
    other.exec_params("UPDATE meals SET description = 'other' WHERE id = $1", [first.id])
    yield
    other.exec('COMMIT')
  end

  # The app's transaction: read both rows, then write the second.
  def write_second(other, cross:)
    Meal.transaction do
      Meal.where(id: [first.id, second.id]).pluck(:description)
      if cross
        cross_with(other) { Meal.where(id: second.id).update_all(description: 'app') }
      else
        Meal.where(id: second.id).update_all(description: 'app')
      end
    end
  end

  # What PostgreSQL tells the app's connection, other than errors.
  def capturing_notices
    connection = ActiveRecord::Base.connection.raw_connection
    notices = []
    connection.set_notice_processor { |message| notices << message }
    yield
    notices
  ensure
    connection&.set_notice_processor { |message| warn message }
  end

  it 'saves nothing, raises the conflict, and leaves exactly one "no transaction in progress" warning' do
    other = open_session
    notices = capturing_notices do
      expect { write_second(other, cross: true) }.to raise_error(ActiveRecord::SerializationFailure)
    end

    expect(notices).to eq(["WARNING:  there is no transaction in progress\n"])
    expect(Meal.where(id: [first.id, second.id]).order(:id).pluck(:description)).to eq(%w[other second])
    expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
  ensure
    other&.close
  end

  it 'is tried again by RetryOnConflict, and the next try saves' do
    allow(Rails.error).to receive(:report).and_call_original
    # A base delay of 0 is a wait of 0 seconds. A wait with no number
    # would sleep with no end.
    allow(RetryOnConflict).to receive(:sleep).with(0.0)
    other = open_session
    tries = 0

    notices = capturing_notices do
      RetryOnConflict.call(base_delay: 0.0) do
        tries += 1
        write_second(other, cross: tries == 1)
      end
    end

    expect(tries).to eq(2)
    expect(notices).to eq(["WARNING:  there is no transaction in progress\n"])
    expect(Meal.where(id: [first.id, second.id]).order(:id).pluck(:description)).to eq(%w[other app])
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(ActiveRecord::SerializationFailure), hash_including(handled: true)).once
  ensure
    other&.close
  end

  # Mutant runs this file before the other examples of RetryOnConflict,
  # and stops at the first one that fails. A change that never gives up
  # would run this block until mutant's time limit, so the block raises a
  # plain error, which is not retried, on one try too many.
  it 'is given up after the tries RetryOnConflict allows when every COMMIT is refused, and raises the conflict' do
    allow(Rails.error).to receive(:report)
    allow(RetryOnConflict).to receive(:sleep).with(0.0)
    other = open_session
    tries = 0

    expect do
      RetryOnConflict.call(base_delay: 0.0) do
        tries += 1
        raise "tried #{tries} times" if tries > RetryOnConflict::MAX_ATTEMPTS

        write_second(other, cross: true)
      end
    end.to raise_error(ActiveRecord::SerializationFailure)

    expect(tries).to eq(RetryOnConflict::MAX_ATTEMPTS)
    expect(Meal.where(id: [first.id, second.id]).order(:id).pluck(:description)).to eq(%w[other second])
  ensure
    other&.close
  end
end
