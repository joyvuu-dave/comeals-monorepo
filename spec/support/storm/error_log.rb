# frozen_string_literal: true

require 'json'

module Storm
  # Everything the app reports through Rails.error during a real-server
  # storm, from every process: the storm server, the jobs process and the
  # storm task. Each process writes one JSON line per report to the same
  # file (STORM_ERROR_LOG, set by bin/storm), and the storm task reads the
  # file after the storm. The in-process storm subscribes in the spec
  # instead (spec/concurrency/request_storm_spec.rb); this is the same
  # idea across processes.
  #
  # config/environments/test.rb subscribes it when STORM_ERROR_LOG is set.
  class ErrorLog
    # A conflict a RetryOnConflict call tried again reports itself with
    # these in its context; that is a retry, not a loss.
    RETRY_KEYS = %w[attempt max_attempts].freeze

    def initialize(path, process:)
      @path = path
      @process = process
      @lock = Mutex.new
    end

    # Rails.error calls this on the thread that reported. One write per
    # line, in append mode, so lines from other processes do not mix.
    def report(error, handled:, context: {}, **)
      line = "#{JSON.generate(self.class.entry(process: @process, error: error, handled: handled, context: context))}\n"
      @lock.synchronize { File.write(@path, line, mode: 'a') }
    end

    def self.entry(process:, error:, handled:, context:)
      cause = error.cause
      { 'process' => process, 'pid' => ::Process.pid, 'handled' => handled, 'error' => error.class.name,
        'message' => error.message.to_s[0, 300], 'cause' => cause&.class&.name,
        'conflict' => conflict?(error),
        'context' => context.to_h.transform_keys(&:to_s).transform_values { |value| value.to_s[0, 100] } }
    end

    # A refusal from PostgreSQL for a conflict, or an enqueue error that
    # carries one (RetryOnConflict.conflict_in).
    def self.conflict?(error)
      error.is_a?(ActiveRecord::TransactionRollbackError) ||
        error.cause.is_a?(ActiveRecord::TransactionRollbackError)
    end

    def self.read(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    end

    def self.retried_conflict?(entry)
      entry['handled'] && entry['conflict'] && RETRY_KEYS.all? { |key| entry['context'].key?(key) }
    end

    # What a report says went wrong, or nil when it is one the storm
    # allows:
    #
    #   - a conflict that was tried again (counted, not a problem);
    #   - a conflict reported and swallowed anywhere else, the way the
    #     in-process storm allows it (a balance refresh after a settlement
    #     that kept conflicting, a refused cache write), except a job that
    #     could not be queued: a lost push or a lost mail is a problem;
    #   - an error that was raised in the server, because the client
    #     judges the answer it got, or in the storm task, because the
    #     thread that raised it judges it (Storm::Run).
    #
    # Everything else is a problem: something went wrong, and in the
    # jobs process nobody else sees it.
    def self.problem(entry)
      text = "#{entry['error']}: #{entry['message']}"
      return "#{entry['process']} raised: #{text}" if !entry['handled'] && entry['process'] == 'jobs'
      return if !entry['handled'] || retried_conflict?(entry)
      return "#{entry['process']} reported and swallowed: #{text}" unless entry['conflict']
      return unless entry['context'].keys.intersect?(%w[channel job])

      context = entry['context'].map { |key, value| "#{key}: #{value}" }.join(', ')
      "#{entry['process']} reported and swallowed: #{text} (#{context}): an enqueue that failed after its retries"
    end
  end
end
