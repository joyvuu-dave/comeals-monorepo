# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'shell'

module DeployWatch
  # Every read of the outside world. Nothing here writes. These, and the log
  # stream in Watch, are the only commands the watch sends to Heroku:
  # releases --json, config:get HEROKU_SLUG_COMMIT, maintenance, ps --json,
  # pg:psql with a read-only SELECT, pg:backups, and logs. `heroku
  # releases:info` is never run: it prints the config vars.
  class Reads
    Reading = Struct.new(:ok, :data, :error)
    class Unreadable < StandardError; end

    COMMAND_TIMEOUT = 60
    LOG_LINES = 1500
    SITE_PATHS = ['/', '/api/v1/version'].freeze
    BUGSNAG_API = 'https://api.bugsnag.com'
    # Bugsnag's filter takes "1d" reliably. The time and the stage are then
    # compared here, from what each error says.
    BUGSNAG_ERRORS = 'filters%5Bevent.since%5D%5B%5D%5Btype%5D=eq&filters%5Bevent.since%5D%5B%5D%5Bvalue%5D=1d' \
                     '&sort=last_seen'

    # One text column, one fact per line, and end=ok last, so a read that
    # stopped part way is never taken for an empty answer. The first
    # statement makes the database itself refuse any write in this read.
    def self.database_select(since)
      from = since.utc.strftime("'%Y-%m-%d %H:%M:%S'")
      <<~SQL.gsub(/\s*\n\s*/, ' ').strip
        SELECT 'heartbeat=' || kind || '|' || round(extract(epoch FROM (now() AT TIME ZONE 'utc') - max(last_heartbeat_at))) AS line
        FROM solid_queue_processes GROUP BY kind
        UNION ALL SELECT 'failed_new=' || count(*) FROM solid_queue_failed_executions WHERE created_at >= #{from}
        UNION ALL SELECT 'failed_old=' || count(*) FROM solid_queue_failed_executions WHERE created_at < #{from}
        UNION ALL (SELECT 'failed_first=' || regexp_replace(left(coalesce(error, ''), 300), '\\s+', ' ', 'g')
        FROM solid_queue_failed_executions WHERE created_at >= #{from} ORDER BY created_at LIMIT 1)
        UNION ALL (SELECT 'ledger=' || extract(epoch FROM finished_at)::bigint || '|' || reconciliations_checked || '|' || mismatch_count
        || '|' || regexp_replace(left(coalesce(error, ''), 200), '\\s+', ' ', 'g')
        FROM ledger_check_runs ORDER BY finished_at DESC LIMIT 1)
        UNION ALL SELECT 'job=' || r.task_key || '|' || extract(epoch FROM r.run_at)::bigint || '|' || (j.finished_at IS NOT NULL)
        FROM solid_queue_recurring_executions r JOIN solid_queue_jobs j ON j.id = r.job_id WHERE r.run_at >= #{from}
        UNION ALL SELECT 'end=ok'
      SQL
    end

    def initialize(app:, url:, since:, token:)
      @app = app
      @url = url
      @since = since
      @token = token
    end

    # Never raises: a read that fails in any way is a failed read, so it can
    # only ever show as "could not check".
    def read(kind)
      Reading.new(true, public_send(kind), nil)
    rescue Unreadable => e
      Reading.new(false, nil, e.message)
    rescue StandardError => e
      Reading.new(false, nil, "#{kind}: an answer this script cannot read (#{e.class})")
    end

    # Newest first.
    def release
      releases = JSON.parse(heroku('releases', '--json'))
      commit = heroku('config:get', 'HEROKU_SLUG_COMMIT').strip
      maintenance = heroku('maintenance').strip
      newest = releases.fetch(0)
      releases.each { |release| release.fetch('created_at') }
      raise Unreadable, 'heroku config:get: no commit in the answer' if commit.empty?
      raise Unreadable, "heroku maintenance: the answer was not on or off: #{maintenance}" unless %w[on off].include?(maintenance)

      { version: newest.fetch('version'), status: newest.fetch('status'), commit:, maintenance:, releases: }
    end

    def dynos
      JSON.parse(heroku('ps', '--json')).map do |dyno|
        { name: dyno.fetch('name'), type: dyno.fetch('type'), state: dyno.fetch('state'),
          updated_at: dyno['updated_at'], version: dyno.fetch('release').fetch('version') }
      end
    end

    def site
      SITE_PATHS.to_h do |path|
        result = Shell.run('curl', '-sS', '-L', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '20', "#{@url}#{path}",
                           timeout: COMMAND_TIMEOUT)
        raise Unreadable, "curl #{path}: #{result.error}" unless result.ok

        [path, result.out.strip]
      end
    end

    def database
      out = heroku('pg:psql', '-c', "SET TRANSACTION READ ONLY; #{self.class.database_select(@since)}")
      facts = out.lines.map(&:strip).filter_map { |line| line.split('=', 2) if line.match?(/\A[a-z_]+=/) }
      raise Unreadable, 'heroku pg:psql: the answer stopped part way' unless facts.include?(%w[end ok])

      database_facts(facts)
    end

    def bugsnag
      project = @bugsnag_project ||= bugsnag_project
      bugsnag_get("/projects/#{project}/errors?#{BUGSNAG_ERRORS}")
        .select { |error| error.fetch('release_stages').include?('production') && Time.iso8601(error.fetch('last_seen')) >= @since }
        .map { |error| { name: error.fetch('error_class'), message: error['message'], context: error['context'] } }
    end

    def backups
      heroku('pg:backups')
    end

    # What Heroku holds now. The stream in Watch starts with the same number
    # of older lines.
    def logs
      heroku('logs', '-n', LOG_LINES.to_s)
    end

    private

    def heroku(*args)
      result = Shell.run('heroku', *args, '-a', @app, timeout: COMMAND_TIMEOUT)
      raise Unreadable, "heroku #{args.first}: #{result.error}" unless result.ok

      result.out
    end

    def database_facts(facts)
      {
        heartbeats: heartbeats(values(facts, 'heartbeat')),
        failed_new: values(facts, 'failed_new').first.to_i,
        failed_old: values(facts, 'failed_old').first.to_i,
        failed_first: values(facts, 'failed_first').first,
        ledger: ledger_fact(values(facts, 'ledger').first),
        jobs: values(facts, 'job').map { |value| job_fact(value) }
      }
    end

    def values(facts, name)
      facts.select { |key, _value| key == name }.map(&:last)
    end

    # Solid Queue saves the supervisor's kind with its mode, such as
    # "Supervisor(async)", so the mode is cut off, as lib/solid_queue_check.rb
    # does. Two rows can then share a kind; the newer heartbeat counts.
    def heartbeats(lines)
      lines.each_with_object({}) do |line, ages|
        kind, age = line.split('|')
        kind = kind.sub(/\(\w+\)\z/, '')
        ages[kind] = [ages[kind], age.to_i].compact.min
      end
    end

    def ledger_fact(value)
      return unless value

      at, checked, mismatches, error = value.split('|', 4)
      { at: Time.at(at.to_i), checked: checked.to_i, mismatches: mismatches.to_i, error: error.to_s }
    end

    def job_fact(value)
      key, at, finished = value.split('|')
      { key:, at: Time.at(at.to_i).utc, finished: finished == 'true' }
    end

    def bugsnag_project
      organization = bugsnag_get('/user/organizations').fetch(0).fetch('id')
      bugsnag_get("/organizations/#{organization}/projects").find { |project| project['slug'] == 'comeals' }.fetch('id')
    end

    # The token goes to curl on its input (-K -), never on the command line.
    def bugsnag_get(path)
      result = Shell.run('curl', '-sS', '-f', '--max-time', '20', '-K', '-', '-H', 'X-Version: 2', "#{BUGSNAG_API}#{path}",
                         input: %(header = "Authorization: token #{@token}"\n), timeout: COMMAND_TIMEOUT)
      raise Unreadable, "Bugsnag: #{result.error}" unless result.ok

      JSON.parse(result.out)
    end
  end
end
