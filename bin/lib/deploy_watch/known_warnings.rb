# frozen_string_literal: true

module DeployWatch
  # docs/deploy-known-warnings.txt, the list bin/deploy reads through
  # bin/lib/deploy-warnings. bin/deploy's reader is Python and this one is
  # Ruby, because this script is Ruby and asks about one line at a time.
  # There is one list. spec/bin/watch_deploy_units_spec.rb checks that both
  # readers give the same answer for the same lines.
  class KnownWarnings
    class ListError < StandardError; end

    WARNING = /warning|warn --|warn:|deprecat/i
    ANSI = /\e\[[0-9;]*m/
    PREFIXES = [
      /\Aremote:\s*/,
      /\A\S+ (?:app|heroku)\[[^\]]+\]:\s*/,
      /\A[DIWEFAU], \[[^\]]*\]\s+/
    ].freeze
    FIELDS = %w[fixed regex app why].freeze
    STAGES = { 'comeals-monorepo' => 'production', 'comeals-staging' => 'staging' }.freeze

    # A log line without what comes before it and changes each time.
    def self.clean(line)
      PREFIXES.inject(line.gsub(ANSI, '').strip) { |text, prefix| text.sub(prefix, '').strip }
    end

    def initialize(path, app)
      @entries = parse(File.readlines(path, chomp: true, encoding: 'UTF-8'))
                 .each { |entry| check(entry) }
                 .select { |entry| ['both', STAGES.fetch(app)].include?(entry['app']) }
    rescue SystemCallError, RegexpError => e
      raise ListError, e.message
    end

    # Why this cleaned line is fine, or nil when the list does not know it.
    def reason(text)
      found = @entries.find do |entry|
        entry['fixed'] ? text.include?(entry['fixed']) : entry['regex'].match?(text)
      end
      found&.fetch('why')
    end

    private

    def parse(lines)
      groups = lines.reject { |line| line.start_with?('#') }
                    .slice_when { |a, b| a.strip.empty? || b.strip.empty? }
                    .reject { |group| group.first.strip.empty? }
      groups.map { |group| group.to_h { |line| field(line) } }
    end

    def field(line)
      name, value = line.split(':', 2)
      raise ListError, "unknown field in: #{line}" unless value && FIELDS.include?(name)

      [name, name == 'regex' ? Regexp.new(value.strip) : value.strip]
    end

    def check(entry)
      return if entry['why'] && (entry['fixed'] || entry['regex']) && %w[production staging both].include?(entry['app'])

      raise ListError, "entry needs why:, app: and fixed: or regex:: #{entry.keys.join(', ')}"
    end
  end
end
