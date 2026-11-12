# frozen_string_literal: true

require 'open3'
require 'socket'

module Faults
  # A PostgreSQL server of the fault suite's own (challenge 30): its own
  # data folder under tmp/faults and its own port. The fault suite
  # restarts it in the middle of a storm. The server the worktrees and
  # the development database share is never stopped or restarted.
  #
  # The programs come from `pg_config --bindir`, so the server is the
  # same PostgreSQL the specs use (18 on the laptop and on CI).
  class Server
    attr_reader :port, :directory

    def initialize(directory:)
      @directory = Pathname(directory)
      @port = nil
    end

    def start
      FileUtils.mkdir_p(@directory)
      initdb unless data.join('PG_VERSION').exist?
      @port = free_port
      pg_ctl('start', '-w', '-l', log.to_s, '-o', settings)
      self
    end

    # pg_ctl restart -m fast: every session is ended, the way a database
    # that crashed and came back, or a failover, ends them.
    def restart
      pg_ctl('restart', '-w', '-m', 'fast', '-l', log.to_s, '-o', settings)
    end

    def stop
      return unless @port && data.join('postmaster.pid').exist?

      pg_ctl('stop', '-w', '-m', 'fast')
    end

    # A new database every time: one a run before left behind is dropped
    # first, so each run starts from the schema alone.
    def create_database(name, schema:)
      run('psql', '-h', '127.0.0.1', '-p', @port.to_s, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q',
          '-c', %(DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)), '-c', %(CREATE DATABASE "#{name}"))
      run('psql', '-h', '127.0.0.1', '-p', @port.to_s, '-d', name, '-v', 'ON_ERROR_STOP=1', '-q',
          '-f', schema.to_s)
    end

    private

    def data = @directory.join('data')
    def log = @directory.join('server.log')

    def initdb
      run(bin('initdb'), '-D', data.to_s, '-U', ENV.fetch('USER', 'postgres'), '--auth=trust', '-E', 'UTF8',
          '--no-instructions')
    end

    # Its socket goes in its own folder, not /tmp, so it cannot be taken
    # for the shared server's.
    def settings = "-p #{@port} -c listen_addresses=127.0.0.1 -k #{@directory} -c fsync=off -c max_connections=200"

    def pg_ctl(*) = run(bin('pg_ctl'), '-D', data.to_s, *)

    def bin(name) = File.join(run('pg_config', '--bindir').strip, name)

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      server.addr[1]
    ensure
      server&.close
    end

    def run(*command)
      output, status = Open3.capture2e(*command)
      raise "#{command.first(2).join(' ')} failed:\n#{output}" unless status.success?

      output
    end
  end
end
