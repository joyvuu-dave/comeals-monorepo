# frozen_string_literal: true

require 'socket'

module Faults
  # A TCP proxy for the fault suite (challenge 30). It listens on a free
  # port on 127.0.0.1 and passes every connection through to the
  # upstream port, byte for byte, until it is told to break things:
  #
  #   cut    closes every open connection at once, both ends, the way a
  #          dropped network or a restarted router does. A new connection
  #          goes through as normal.
  #   down   closes the listening port too, so a new connection is
  #          refused, the way a server that is gone is. up opens it again
  #          on the same port.
  #
  # Each connection is two threads, one for each direction. It is for
  # tests on one machine, not for speed.
  class Proxy
    attr_reader :port, :cuts

    def initialize(upstream_port:, upstream_host: '127.0.0.1', port: 0)
      @upstream_host = upstream_host
      @upstream_port = upstream_port
      @lock = Mutex.new
      @pairs = []
      @cuts = 0
      @server = TCPServer.new('127.0.0.1', port)
      @port = @server.addr[1]
      @acceptor = start_accepting(@server)
    end

    def open_connections = @lock.synchronize { @pairs.size }

    # Closes every open connection, and returns how many there were.
    def cut
      pairs = @lock.synchronize do
        @cuts += 1
        @pairs.dup.tap { @pairs.clear }
      end
      pairs.each { |pair| close(pair) }
      pairs.size
    end

    def down
      server = @lock.synchronize { @server.tap { @server = nil } }
      return unless server

      server.close
      @acceptor.join(5)
      cut
    end

    def up
      @lock.synchronize do
        return if @server

        @server = TCPServer.new('127.0.0.1', @port) # Ruby sets SO_REUSEADDR, so the port is free again
      end
      @acceptor = start_accepting(@server)
    end

    def stop
      down
    end

    private

    def start_accepting(server)
      Thread.new do
        Thread.current.report_on_exception = false
        loop { pass_through(server.accept) }
      rescue IOError, Errno::EBADF, Errno::EINVAL
        nil # the listening port was closed: down or stop
      end
    end

    def pass_through(client)
      upstream = TCPSocket.new(@upstream_host, @upstream_port)
      pair = [client, upstream]
      @lock.synchronize { @pairs << pair }
      [[client, upstream], [upstream, client]].each do |from, to|
        Thread.new do
          Thread.current.report_on_exception = false
          IO.copy_stream(from, to)
        rescue IOError, SystemCallError
          nil # one end was closed: by cut, or by the other side
        ensure
          forget(pair)
        end
      end
    rescue SystemCallError
      client.close
    end

    # One end finished: the other one is closed too, as a real network
    # connection would be.
    def forget(pair)
      gone = @lock.synchronize { @pairs.delete(pair) }
      close(pair) if gone
    end

    def close(pair)
      pair.each do |socket|
        socket.close
      rescue IOError
        nil
      end
    end
  end
end
