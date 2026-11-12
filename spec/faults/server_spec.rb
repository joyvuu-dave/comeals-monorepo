# frozen_string_literal: true

require 'rails_helper'

# The fault suite (challenge 30) restarts PostgreSQL in the middle of a
# storm. It must never restart the server every worktree and the
# development database share, so it starts one of its own.
RSpec.describe Faults::Server do
  let(:server) { described_class.new(directory: Rails.root.join('tmp/faults/server_spec')) }

  after { server.stop }

  def connect = PG.connect(host: '127.0.0.1', port: server.port, dbname: 'postgres', connect_timeout: 5)

  it 'starts a PostgreSQL of its own, on its own port' do
    server.start
    expect(server.port).not_to eq(5432)
    connection = connect
    expect(connection.exec('SHOW data_directory').getvalue(0, 0)).to start_with(Rails.root.join('tmp/faults').to_s)
  ensure
    connection&.close
  end

  it 'restarts: an open connection is gone, and a new one works' do
    server.start
    before = connect
    server.restart

    expect { before.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)
    after = connect
    expect(after.exec('SELECT 1').getvalue(0, 0)).to eq('1')
  ensure
    after&.close
  end

  it 'makes a database with the app schema in it' do
    server.start
    server.create_database('comeals_faults', schema: Rails.root.join('db/structure.sql'))
    connection = PG.connect(host: '127.0.0.1', port: server.port, dbname: 'comeals_faults')
    tables = connection.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").column_values(0)
    expect(tables).to include('meals', 'meal_residents', 'bills', 'reconciliations')
  ensure
    connection&.close
  end

  it 'is stopped after stop, and stop twice does nothing' do
    server.start
    server.stop
    expect { connect }.to raise_error(PG::ConnectionBad)
    expect { server.stop }.not_to raise_error
  end
end
