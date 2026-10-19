# frozen_string_literal: true

require 'stringio'

# Line coverage for the bash scripts this repository holds at 100%. Each
# script is run under bashcov by one spec file, and an after(:context) hook
# in that file calls #check!. The counts stay in this object: nothing here
# touches the SimpleCov result of the Ruby code.
#
# To hold another script at 100%:
#   1. add it to FILES below, with the spec file that runs it;
#   2. in that spec file, make one BashCoverage.new(<that spec file>), run
#      the script through its #run, and call its #check! in after(:context)
#      when every example of the file ran (spec/bin/deploy_spec.rb shows how).
# CI splits the suite by spec file (bin/rspec-shard), so a spec file always
# runs whole on one shard and its check sees every run.
class BashCoverage
  ROOT = File.expand_path('../..', __dir__)

  # Every bash file held at 100%, and the spec file that must run all of it.
  FILES = {
    'bin/deploy' => 'spec/bin/deploy_spec.rb',
    'bin/lib/output.sh' => 'spec/bin/deploy_spec.rb'
  }.freeze

  # bashcov marks a line that holds a whole function, `red() { ...; }`, as
  # relevant only once the function runs. So it never reports one that did
  # not run, and the check adds these lines itself.
  ONE_LINE_FUNCTION = /\A\s*\w+\(\)\s*\{.*\}\s*\z/
  LOOP_START = /;\s*do\s*\z/
  LOOP_END = /\A\s*done\b/

  def initialize(spec_file)
    files = FILES.select { |_, spec| spec == spec_file }.keys
    raise "BashCoverage::FILES names no script for #{spec_file}" if files.empty?

    # { absolute path => [count, or nil for a line bashcov does not count] }
    @counts = files.to_h { [File.join(ROOT, it), []] }
  end

  # bashcov needs bash 4.1 or newer (BASH_XTRACEFD), and these specs use
  # bash 5. macOS ships 3.2 as /bin/bash, so look on the PATH first.
  def bash
    @bash ||= begin
      candidates = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { File.join(it, 'bash') } + ['/bin/bash']
      found = candidates.find do |path|
        File.executable?(path) && IO.popen([path, '-c', 'echo ${BASH_VERSINFO[0]}'], &:read).to_i >= 5
      end
      found || raise('The bash coverage specs need bash 5 or newer on the PATH (macOS: brew install bash)')
    end
  end

  # Runs `bash *args` under bashcov, adds the lines that ran, and returns
  # the Process::Status. Any warning from bashcov fails the run: "Aborting
  # early" means the counts are incomplete, and a script it drops for bad
  # syntax would never be counted.
  def run(*args)
    require 'bashcov'
    require 'bashcov/runner'
    # skip_uncovered: without it bashcov walks the whole repository
    # (node_modules too) for scripts that did not run.
    Bashcov.skip_uncovered = true
    Bashcov.bash_path = bash
    runner = Bashcov::Runner.new([bash, *args])
    status, result, warnings = with_warnings_captured { [runner.run, runner.result] }
    raise "bashcov warned, so its counts cannot be trusted:\n#{warnings}" unless warnings.empty?

    add(result)
    status
  end

  # Raises unless every line bashcov counts, and every one-line function,
  # ran at least once.
  def check!
    missed = @counts.flat_map do |file, counts|
      raise "#{file} never ran under bashcov" if counts.empty?

      lines = File.readlines(file)
      ran = counts_per_command(lines, counts)
      lines.each_with_index.filter_map do |text, index|
        required = !counts[index].nil? || text.match?(ONE_LINE_FUNCTION)
        "#{file.delete_prefix("#{ROOT}/")}:#{index + 1}: #{text.strip}" if required && ran[index].zero?
      end
    end
    return if missed.empty?

    raise "#{@counts.keys.map { it.delete_prefix("#{ROOT}/") }.join(' and ')} must run every line. " \
          "These did not:\n#{missed.join("\n")}"
  end

  private

  def add(result)
    result.each do |file, data|
      totals = @counts[File.realpath(file)] or next

      data['lines'].each_with_index do |count, line|
        totals[line] = totals[line].to_i + count unless count.nil?
      end
    end
  end

  # bashcov writes its warnings with Kernel#warn, to $stderr.
  def with_warnings_captured
    original = $stderr
    $stderr = StringIO.new
    [*yield, $stderr.string]
  ensure
    $stderr = original
  end

  # bash's trace names one line for a command that spans several, so
  # bashcov can mark a line relevant that the trace never names:
  #   - a command continued with a backslash is traced as one of its lines
  #     (gh api ... \ --jq ..., heroku releases ... | python3 -c \);
  #   - a loop's `done <<< "$runs"` line is never traced; its first line is.
  # Each line here gets the largest count of the command it belongs to.
  def counts_per_command(lines, counts)
    groups = Array.new(lines.size) { [it] }
    loops = []
    lines.each_with_index do |text, index|
      groups[index] = groups[index - 1] << index if index.positive? && lines[index - 1].rstrip.end_with?('\\')
      loops << index if text.match?(LOOP_START)
      groups[index] = (groups[index] + [loops.pop]).compact if text.match?(LOOP_END)
    end
    groups.map { |group| group.map { counts[it].to_i }.max }
  end
end
