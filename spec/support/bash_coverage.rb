# frozen_string_literal: true

# Line coverage for the bash scripts this repository holds at 100%,
# measured with bashcov's trace format, parser and lexer (#run says why it
# does not use bashcov's runner). Each script is run by one spec file, and an after(:context) hook
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
    'bin/lib/output.sh' => 'spec/bin/deploy_spec.rb',
    'bin/lib/staging_forbidden_vars.sh' => 'spec/bin/deploy_spec.rb',
    'bin/agent-merge' => 'spec/bin/agent_merge_spec.rb',
    'bin/agent-worktree' => 'spec/bin/agent_worktree_spec.rb',
    'bin/agent-worktree-done' => 'spec/bin/agent_worktree_done_spec.rb',
    'bin/check' => 'spec/bin/check_spec.rb',
    'bin/dev' => 'spec/bin/dev_spec.rb',
    'bin/mutant' => 'spec/bin/mutant_spec.rb',
    'bin/prod' => 'spec/bin/prod_spec.rb',
    'bin/storm' => 'spec/bin/storm_spec.rb',
    'bin/test-integration' => 'spec/bin/test_integration_spec.rb',
    'bin/update-linux-snapshots' => 'spec/bin/update_linux_snapshots_spec.rb',
    'bin/update-snapshots' => 'spec/bin/update_snapshots_spec.rb',
    'bin/visual-coverage' => 'spec/bin/visual_coverage_spec.rb',
    'bin/visual-linux' => 'spec/bin/visual_linux_spec.rb',
    'bin/staging-rehearsal' => 'spec/bin/staging_rehearsal_spec.rb',
    'bin/smoke' => 'spec/bin/smoke_spec.rb',
    'bin/rollback-check' => 'spec/bin/rollback_check_spec.rb',
    'bin/lib/json.sh' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/compare' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/green-gate' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/hold-check' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/ping-healthchecks' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/promote' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/watch-production' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/deploy/write-release-note' => 'spec/bin/deploy_workflow_spec.rb',
    'bin/lib/playwright-install' => 'spec/bin/playwright_install_spec.rb',
    'bin/lib/rollback/check-migrations' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/file-issue' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/find-release' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/mark-release-notes' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/restore-backup' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/roll-back' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/say-what-to-do' => 'spec/bin/rollback_workflow_spec.rb',
    'bin/lib/rollback/start-web' => 'spec/bin/rollback_workflow_spec.rb'
  }.freeze

  # bashcov marks a line that holds a whole function, `red() { ...; }`, as
  # relevant only once the function runs. So it never reports one that did
  # not run, and the check adds these lines itself.
  ONE_LINE_FUNCTION = /\A\s*\w+\(\)\s*\{.*\}\s*\z/
  LOOP_START = /;\s*do\s*\z/
  LOOP_END = /\A\s*done\b/
  # LINENO, BASH_SOURCE, PWD and OLDPWD (Bashcov::Xtrace::FIELDS).
  FIELD_COUNT = 4

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

  # Runs `bash *args` with bash's trace on, the way bashcov does, and adds
  # the lines that ran. Returns the Process::Status.
  #
  # bashcov's own runner reads the trace from a pipe in a thread while the
  # script runs. In CI that once lost a line with no warning (a run of
  # spec/bin/deploy_spec.rb on 2026-10-19 never counted bin/deploy:449,
  # though the example that runs it passed). So the trace goes to a file
  # instead, and is read with bashcov's own parser only after the script
  # has ended. Then the run fails, loudly, unless every trace record the
  # file holds was read whole: TraceLost says the counts cannot be trusted.
  def run(*args)
    load_bashcov
    Dir.mktmpdir('bash-trace') do |dir|
      trace_path = File.join(dir, 'trace')
      status = trace_to(trace_path, args)
      add(read_trace(trace_path))
      status
    end
  end

  class TraceLost < StandardError; end

  def load_bashcov
    require 'bashcov'
    require 'bashcov/lexer'
    require 'bashcov/xtrace'
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

  # Each process appends whole records to the file (O_APPEND), so records
  # from a pipeline's processes cannot land inside each other the way they
  # can in a pipe that a reader drains while they write.
  def trace_to(trace_path, args)
    File.open(trace_path, File::WRONLY | File::CREAT | File::APPEND) do |trace|
      fd = trace.fileno
      env = { 'PS4' => Bashcov::Xtrace.ps4, 'BASH_XTRACEFD' => fd.to_s, 'SHELLOPTS' => 'xtrace' }
      Process.wait2(Process.spawn(env, bash, *args, fd => fd)).last
    end
  end

  # { absolute path => [count, or nil for a line that did not run] } for
  # the files this object holds, with bashcov's Lexer marking the lines
  # that count.
  def read_trace(trace_path)
    hits = @counts.keys.index_with { [] }
    trace_records(trace_path).each do |lineno, source|
      counts = hits[File.realpath(source)] or next
      counts[lineno - 1] = counts[lineno - 1].to_i + 1
    end
    hits.reject { |_, counts| counts.empty? }.each { |file, counts| Bashcov::Lexer.new(file, counts).complete_coverage }
  end

  # [[line number, script], ...], one per trace record. A record is
  # bashcov's PS4: a start field ending in "+BASHCOV>", then line number,
  # script, PWD and OLDPWD, each ended by bashcov's delimiter; the command
  # text that follows ends up in the next record's start field. Raises
  # TraceLost unless every record bash wrote has exactly those four fields,
  # a line number, and a script that exists.
  def trace_records(trace_path)
    delimiter = Bashcov::Xtrace.delimiter
    text = File.binread(trace_path)
    records = split_records(text, delimiter)
    # The last record also holds the command text that follows it.
    records.last&.pop if records.last&.size == FIELD_COUNT + 1
    check_whole(records, text.scan("#{Bashcov::Xtrace::PREFIX}#{delimiter}").size)
    # bash sometimes prints PS4 without expanding it, and `bash -c` code has
    # no script; bashcov skips both.
    records.filter_map do |lineno, source, pwd, _|
      [lineno.to_i, File.expand_path(source, pwd)] unless lineno == '${LINENO-}' || source.empty?
    end
  end

  def split_records(text, delimiter)
    text.split(delimiter, -1).each_with_object([]) do |field, records|
      if field.match?(Bashcov::Xtrace::PS4_START_REGEXP) then records << []
      elsif records.any? then records.last << field
      end
    end
  end

  def whole_record?(lineno = nil, source = nil, pwd = nil, *rest)
    return false unless rest.size == 1 && pwd
    return true if lineno == '${LINENO-}'

    lineno.match?(/\A\d+\z/) && (source.empty? || File.file?(File.expand_path(source, pwd)))
  end

  def check_whole(records, written)
    raise TraceLost, "bash wrote #{written} trace records and #{records.size} were read" unless records.size == written

    broken = records.find { |record| !whole_record?(*record) }
    raise TraceLost, "a bash trace record is broken: #{broken.inspect}" if broken
  end

  def add(result)
    result.each do |file, lines|
      totals = @counts.fetch(file)
      lines.each_with_index do |count, line|
        totals[line] = totals[line].to_i + count unless count.nil?
      end
    end
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
