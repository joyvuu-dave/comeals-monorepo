# frozen_string_literal: true

# The lines of bin/deploy and bin/lib/output.sh that ran, summed over the
# bashcov runs of spec/bin/deploy_spec.rb, and the check that holds them at
# 100%. It never touches the SimpleCov result of the Ruby code.
class BashCoverage
  ROOT = File.expand_path('../../..', __dir__)
  FILES = %w[bin/deploy bin/lib/output.sh].map { File.join(ROOT, it) }.freeze

  # bashcov marks a line that holds a whole function, `red() { ...; }`, as
  # relevant only once the function runs. So it never reports one that did
  # not run, and the check adds these lines itself.
  ONE_LINE_FUNCTION = /\A\s*\w+\(\)\s*\{.*\}\s*\z/
  LOOP_START = /;\s*do\s*\z/
  LOOP_END = /\A\s*done\b/

  def initialize
    # { path => [count, or nil for a line bashcov does not count] }
    @counts = FILES.index_with { [] }
  end

  # Adds one Bashcov::Runner#result.
  def add(result)
    result.each do |file, data|
      totals = @counts[File.realpath(file)] or next

      data['lines'].each_with_index do |count, line|
        totals[line] = totals[line].to_i + count unless count.nil?
      end
    end
  end

  # Raises unless every line bashcov counts, and every one-line function,
  # ran at least once.
  def check!
    missed = FILES.flat_map do |file|
      counts = @counts.fetch(file)
      raise "#{file} never ran under bashcov" if counts.empty?

      lines = File.readlines(file)
      ran = counts_per_command(lines, counts)
      lines.each_with_index.filter_map do |text, index|
        required = !counts[index].nil? || text.match?(ONE_LINE_FUNCTION)
        "#{file.delete_prefix("#{ROOT}/")}:#{index + 1}: #{text.strip}" if required && ran[index].zero?
      end
    end
    return if missed.empty?

    raise 'bin/deploy and bin/lib/output.sh must run every line under spec/bin/deploy_spec.rb. ' \
          "These did not:\n#{missed.join("\n")}"
  end

  private

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
