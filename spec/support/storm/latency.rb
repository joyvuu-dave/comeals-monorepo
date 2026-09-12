# frozen_string_literal: true

require 'json'

module Storm
  # How long the requests took, from the client's side.
  #
  # Percentiles, not averages: an average hides the slow tail, and the
  # slow tail is what a person notices. p50 is the typical request, p95
  # is what one request in twenty sees, p99 one in a hundred, max the
  # worst. Per action, because a calendar month and a sign-up are not
  # the same request, and overall.
  #
  # The numbers mean something only against a baseline on the same
  # machine with the same settings — a laptop on battery is not a dyno.
  # So a run saves its numbers, and the next run with the same shape
  # prints them side by side. `Latency.compare` is that; the shape is
  # the clients and the seconds, which is what the driver knows.
  class Latency
    PERCENTILES = { p50: 0.50, p95: 0.95, p99: 0.99 }.freeze

    Summary = Struct.new(:requests, :p50, :p95, :p99, :slowest, keyword_init: true) do
      def to_s
        format('n=%<requests>-5d p50=%<p50>7.1fms  p95=%<p95>7.1fms  p99=%<p99>7.1fms  max=%<slowest>8.1fms',
               requests: requests, p50: p50, p95: p95, p99: p99, slowest: slowest)
      end
    end

    # requests: the storm's Entry list. Entries with no timing (an
    # exception out of the transport) are left out; they are problems,
    # counted elsewhere.
    def initialize(requests, seconds:)
      @timed = requests.select(&:ms)
      @seconds = seconds
    end

    def overall
      summarize(@timed.map(&:ms))
    end

    def by_action
      @timed.group_by(&:action).sort.to_h { |action, list| [action, summarize(list.map(&:ms))] }
    end

    # Requests answered per second, over the whole run, every client
    # together. Load, not speed: it falls when the server is slow and
    # when the clients are few.
    def throughput
      (@timed.size / @seconds.to_f).round(1)
    end

    def report
      lines = ["latency (client side), #{throughput} requests/s over #{@seconds}s",
               "  #{'all'.ljust(20)} #{overall}"]
      by_action.each { |action, summary| lines << "  #{action.to_s.ljust(20)} #{summary}" }
      lines.join("\n")
    end

    # --- the baseline -------------------------------------------------------

    def to_h
      { 'throughput' => throughput, 'overall' => overall.to_h,
        'by_action' => by_action.to_h { |action, summary| [action.to_s, summary.to_h] } }
    end

    # Saves this run under a key for its shape and returns the previous
    # run of the same shape, or nil.
    def self.record(latency, path:, shape:)
      all = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      previous = all[shape]
      all[shape] = latency.to_h.merge('at' => Time.now.utc.iso8601)
      File.write(path, JSON.pretty_generate(all))
      previous
    end

    # The change since the previous run of the same shape, as text.
    def self.compare(latency, previous)
      return 'no previous run of this shape to compare with' if previous.nil?

      now = latency.overall
      then_ = previous.fetch('overall')
      changes = %w[p50 p95 p99 slowest].map do |key|
        before = then_.fetch(key)
        after = now[key.to_sym]
        pct = before.zero? ? 0 : ((after - before) / before * 100).round
        format('%<key>s %<before>.1f -> %<after>.1f ms (%<sign>s%<pct>d%%)', key: key, before: before, after: after,
                                                                             sign: pct.positive? ? '+' : '', pct: pct)
      end
      "since #{previous.fetch('at')} (#{previous.fetch('throughput')} -> #{latency.throughput} req/s): " \
        "#{changes.join(', ')}"
    end

    private

    def summarize(values)
      return Summary.new(requests: 0, p50: 0.0, p95: 0.0, p99: 0.0, slowest: 0.0) if values.empty?

      sorted = values.sort
      Summary.new(requests: sorted.size, slowest: sorted.last,
                  **PERCENTILES.transform_values { |quantile| percentile(sorted, quantile) })
    end

    # Nearest-rank: the value at the ceiling of quantile * n, one-based.
    # The common definition, and the one that never invents a value.
    def percentile(sorted, quantile)
      sorted[[(quantile * sorted.size).ceil, 1].max - 1]
    end
  end
end
