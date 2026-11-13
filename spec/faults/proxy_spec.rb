# frozen_string_literal: true

require 'rails_helper'

# The fault suite (challenge 30) puts this proxy between the server and
# PostgreSQL, so it can cut every connection in the middle of a write.
RSpec.describe Faults::Proxy do
  let(:config) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:proxy) { described_class.new(upstream_port: config.fetch(:port, 5432)) }

  after { proxy.stop }

  # The test database's own login: in CI it is postgres with a password
  # (DATABASE_URL); on the laptop it is the user running the specs.
  def connect
    PG.connect(host: '127.0.0.1', port: proxy.port, dbname: config[:database], user: config[:username],
               password: config[:password], connect_timeout: 5)
  end

  it 'passes a connection through to PostgreSQL' do
    connection = connect
    expect(connection.exec('SELECT 1 + 1 AS two').getvalue(0, 0)).to eq('2')
    expect(proxy.open_connections).to eq(1)
  ensure
    connection&.close
  end

  it 'cuts every open connection, and lets a new one through after' do
    first = connect
    second = connect
    expect(proxy.cut).to eq(2)

    expect { first.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)
    expect { second.exec('SELECT 1') }.to raise_error(PG::ConnectionBad)
    expect(proxy.open_connections).to eq(0)

    third = connect
    expect(third.exec('SELECT 1').getvalue(0, 0)).to eq('1')
  ensure
    [first, second, third].compact.each { it.close unless it.finished? }
  end

  it 'refuses new connections while it is down, and takes them again when it is up' do
    proxy.down
    expect { connect }.to raise_error(PG::ConnectionBad)

    proxy.up
    connection = connect
    expect(connection.exec('SELECT 1').getvalue(0, 0)).to eq('1')
  ensure
    connection&.close
  end

  # PostgreSQL restarting closes its end of every connection while a
  # client waits for an answer. The client must see its connection end,
  # as it would without the proxy. In CI (Linux) the proxy once closed
  # its end of the client socket from one thread while the other thread
  # was still reading it, the close never finished, and the client waited
  # for an answer for good.
  it 'ends the client side when the server closes its side' do
    server = TCPServer.new('127.0.0.1', 0)
    serving = Thread.new do
      upstream = server.accept
      upstream.readpartial(5)
      upstream.close
    end
    other = described_class.new(upstream_port: server.addr[1])
    client = TCPSocket.new('127.0.0.1', other.port)
    client.write('query')

    expect(client.wait_readable(5)).to be_truthy, 'the client was still waiting after 5 seconds'
    expect(client.read).to eq('')
  ensure
    serving&.join(5)
    client&.close
    other&.stop
    server&.close
  end

  it 'counts what it cut' do
    connection = connect
    proxy.cut
    expect(proxy.cuts).to eq(1)
  ensure
    connection&.close unless connection&.finished?
  end
end
