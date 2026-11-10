# frozen_string_literal: true

# Compares the survivors of a mutant run with the list of accepted
# survivors in config/mutant/accepted_survivors/, one YAML file for each
# class (docs/mutation-testing.md, "Accepted survivors"). bin/mutant-report uses it for a run on GitHub,
# and bin/mutant-survivors for a run on this machine.
#
# A survivor is accepted when the list has an entry with the same subject
# and the same diff. The diff is the whole method before and after the
# change, so any edit to the method changes it, and the entry no longer
# matches. Someone then has to read that survivor again.
#
# Ruby's standard library only: the workflow's last job runs it without
# the bundle.

require 'json'
require 'yaml'
require 'zlib'

module MutantSurvivors
  # The specs point MUTANT_ACCEPTED_SURVIVORS at a folder of their own.
  LIST = ENV.fetch('MUTANT_ACCEPTED_SURVIVORS', File.expand_path('../../config/mutant/accepted_survivors', __dir__))

  # same-answer: no caller can see the change; the method gives the same
  #   answer for every input it can be given.
  # never-ends: the change makes a loop that never ends, so every example
  #   that reaches it hangs until the timeout or the memory limit stops it.
  #   A hang is not a failure mutant can count.
  KINDS = %w[same-answer never-ends].freeze
  PLATFORMS = %w[linux].freeze
  KEYS = %w[subject kind why diff].freeze
  OPTIONAL_KEYS = %w[only_on].freeze

  # One mutation from a session file.
  Mutation = Struct.new(:subject, :place, :diff, :neutral, :alive, :timeout, :aborted, keyword_init: true) do
    def key = [subject, MutantSurvivors.normal(diff)]

    # How the mutation lived, in words for the report.
    def how
      if neutral then 'the examples fail on the code as written'
      elsif timeout then 'timed out'
      elsif aborted then 'its process ended with an error'
      else 'lived'
      end
    end
  end

  Entry = Struct.new(:subject, :kind, :why, :diff, :only_on, keyword_init: true) do
    def key = [subject, MutantSurvivors.normal(diff)]
  end

  # The result of one comparison.
  #   unaccepted: survivors with no entry. Each one needs an example that
  #     kills it, or an entry that says why none can.
  #   accepted: survivors with an entry.
  #   stale: entries for a subject that ran, whose mutation did not survive
  #     (killed, or the method changed). On a full run, also entries whose
  #     subject did not run at all (renamed or removed).
  #   not_here: entries for another platform that did not survive here.
  Comparison = Struct.new(:mutations, :unaccepted, :accepted, :stale, :not_here, keyword_init: true) do
    def passed? = unaccepted.empty? && stale.empty?
  end

  module_function

  # Each line without the spaces at its end, and no newline at the end of
  # the text. An editor or a formatter can drop the space that a blank line
  # of the method has in a diff, so the comparison must not depend on it.
  def normal(diff) = diff.to_s.lines.map(&:rstrip).join("\n").strip

  def platform = RUBY_PLATFORM[/linux/] || RUBY_PLATFORM

  # Every mutation in one session file (.mutant/results/<session>.json.gz).
  def read_session(path)
    json = JSON.parse(Zlib::GzipReader.open(path, &:read))
    json.fetch('subject_results').flat_map do |subject|
      place = place(subject.fetch('identification'))
      subject.fetch('coverage_results').map { |coverage| mutation(subject.fetch('expression_syntax'), place, coverage) }
    end
  end

  def mutation(subject, place, coverage)
    result = coverage.fetch('mutation_result')
    isolation = result.fetch('isolation_result')
    timeout = !isolation.fetch('timeout').nil?
    status = isolation.fetch('process_status')
    Mutation.new(subject: subject, place: place, diff: result.fetch('mutation_diff'),
                 neutral: result.fetch('mutation_type') == 'neutral',
                 alive: !coverage.fetch('criteria_result').fetch('test_result'),
                 timeout: timeout, aborted: !timeout && !status.nil? && status.fetch('exitstatus') != 0)
  end

  # "Foo#bar:/home/runner/work/x/x/app/services/foo.rb:12" -> "app/services/foo.rb:12"
  def place(identification)
    path_and_line = identification.split(':', 2).last
    path_and_line[%r{/((?:app|lib|config)/.+)\z}, 1] || path_and_line
  end

  # The file, inside the folder, that holds a subject's entries: its class
  # in snake case, a folder for each namespace.
  # "Api::V1::MealsController#show" -> "api/v1/meals_controller.yml"
  def file_for(subject)
    names = subject[/\A[^#.]+/].split('::').map do |name|
      name.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end
    "#{names.join('/')}.yml"
  end

  def list_files(dir) = Dir.glob(File.join(dir, '**', '*.yml'))

  def read_list(dir = LIST)
    list_files(dir).flat_map do |path|
      YAML.safe_load_file(path).map { |entry| Entry.new(**entry.transform_keys(&:to_sym)) }
    end
  end

  # Each problem with the list itself, in words. Empty when it is right.
  def list_problems(dir = LIST)
    seen = {}
    list_files(dir).sort.flat_map do |path|
      name = path.delete_prefix("#{dir}/")
      data = YAML.safe_load_file(path)
      next ["#{name} is not a list with at least one entry"] unless data.is_a?(Array) && !data.empty?

      data.each_with_index.flat_map { |entry, index| entry_and_place_problems("#{name}, entry #{index + 1}", entry, name, seen) }
    end
  end

  def entry_and_place_problems(at, data, name, seen)
    return ["#{at} is not a mapping"] unless data.is_a?(Hash)

    problems = entry_problems(at, data)
    subject = data['subject'].to_s
    problems << "#{at} belongs in #{file_for(subject)}" if subject.match?(/\A[A-Z]/) && file_for(subject) != name
    key = [subject, normal(data['diff'])]
    problems << "#{at} repeats #{seen[key]}" if seen[key]
    seen[key] ||= at
    problems
  end

  def entry_problems(at, data)
    problems = []
    missing = KEYS - data.keys
    extra = data.keys - KEYS - OPTIONAL_KEYS
    problems << "#{at} has no #{missing.join(', ')}" unless missing.empty?
    problems << "#{at} has unknown keys #{extra.join(', ')}" unless extra.empty?
    named = "#{at} (#{data['subject']})"
    problems << "#{named}: the kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(data['kind'])
    problems << "#{named}: why is empty" if data['why'].to_s.strip.empty?
    problems << "#{named}: the diff does not start with @@" unless data['diff'].to_s.start_with?('@@')
    if data.key?('only_on') && PLATFORMS.none?(data['only_on'])
      problems << "#{named}: only_on must be one of #{PLATFORMS.join(', ')}"
    end
    problems
  end

  # full: every subject in .mutant.yml ran, so an entry whose subject did
  # not run names a method that was renamed or removed.
  def compare(mutations, entries, full:, here: platform)
    ran = mutations.to_set(&:subject)
    alive = mutations.select(&:alive)
    listed = entries.to_set(&:key)
    accepted, unaccepted = alive.partition { |mutation| !mutation.neutral && listed.include?(mutation.key) }
    not_here, stale = gone(entries, alive, ran, full).partition do |entry|
      entry.only_on && entry.only_on != here && ran.include?(entry.subject)
    end
    Comparison.new(mutations: mutations, unaccepted: unaccepted, accepted: accepted, stale: stale, not_here: not_here)
  end

  # The entries with no survivor to match: for a subject that ran, or on a
  # full run, for any subject.
  def gone(entries, alive, ran, full)
    alive_keys = alive.to_set(&:key)
    entries.reject { |entry| alive_keys.include?(entry.key) || !(full || ran.include?(entry.subject)) }
  end

  # The report's sections on survivors, as Markdown lines.
  def report_lines(comparison)
    lines = []
    lines += unaccepted_lines(comparison.unaccepted)
    lines += stale_lines(comparison.stale)
    lines << '' << "Accepted survivors: #{comparison.accepted.size} (config/mutant/accepted_survivors/)."
    unless comparison.not_here.empty?
      lines << "Entries for another platform that did not survive here: #{comparison.not_here.size}."
    end
    lines
  end

  def unaccepted_lines(unaccepted)
    lines = ["## Survivors not on the list (#{unaccepted.size})"]
    return lines + ['', 'None.'] if unaccepted.empty?

    lines << '' << 'Kill each one with an example, or add its entry to the file named for it, ' \
                   'with the kind and why filled in (docs/mutation-testing.md, "Accepted survivors").'
    unaccepted.sort_by { |mutation| [mutation.place, mutation.subject] }.each do |mutation|
      lines << '' << "### #{mutation.subject}, #{mutation.place}: #{mutation.how}"
      lines << '' << "For config/mutant/accepted_survivors/#{file_for(mutation.subject)}:"
      lines << '' << '```yaml' << entry_yaml(mutation) << '```'
    end
    lines
  end

  def stale_lines(stale)
    return [] if stale.empty?

    lines = ['', "## Entries that no longer survive (#{stale.size})", '',
             'The mutation was killed, the method changed, or the method is gone. Remove each entry; ' \
             'if the method changed, its new survivors are listed above.']
    stale.each do |entry|
      lines << '' << "- #{entry.subject}: #{entry.why}" << '' << '```diff' << normal(entry.diff) << '```'
    end
    lines
  end

  # An entry for the list, with kind and why left for a person to fill in.
  # The list's check refuses an empty why.
  def entry_yaml(mutation)
    kind = mutation.timeout || mutation.aborted ? 'never-ends' : 'same-answer'
    diff = normal(mutation.diff).lines.map { |line| "    #{line}".rstrip }.join("\n")
    "- subject: #{mutation.subject}\n  kind: #{kind}\n  why: \"\"\n  diff: |\n#{diff}"
  end
end
