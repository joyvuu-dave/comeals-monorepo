# frozen_string_literal: true

require 'fileutils'

# Fails the run when anything other than RSpec's own report is written to
# the terminal: a `puts` left in a spec, a Ruby warning, a deprecation, a
# child process that prints, a PostgreSQL warning that libpq prints.
#
# How: before any spec loads, file descriptors 1 and 2 (stdout and stderr)
# are pointed at a file, and RSpec's report goes to copies of the real
# ones. So everything else that writes to stdout or stderr lands in the
# file: Ruby code through $stdout or $stderr, C code in gems (libpq) that
# writes to fd 2, and child processes, which get fd 1 and 2 from this one.
# After each example the new part of the file is read, and an example that
# wrote something fails with that text. Output from outside an example
# (while the spec files load, in a before(:context) hook) is reported when
# the run ends, and fails it.
#
# This is checked at the file descriptors, not by replacing $stdout and
# $stderr with Ruby objects, because libpq and child processes never see
# those objects: the warning this was written for (#164, "there is no
# transaction in progress") came from libpq. And it is checked here, not
# by a grep of the output in bin/check, so that a plain `bundle exec rspec`,
# CI and bin/check all fail the same way, and the failure names the
# example.
#
# A spec that means to print checks the text with RSpec's own matchers:
# `expect { ... }.to output(...).to_stdout` (or `.to_stderr`, or
# `_from_any_process` for a child process). Those replace the stream while
# the block runs, so nothing reaches the file.
#
# To see output while you debug (binding.irb, puts), run with
# RSPEC_STRAY_OUTPUT=show; the check is then off. Mutant runs the examples
# in its own worker processes and handles their output itself, so the
# check is off there too.
class StrayOutput
  # Lines that may be written. Each one needs the reason it is fine.
  # A line that matches any pattern here is dropped; the rest fail.
  ALLOWED = {}.freeze

  # Raised by the check after an example.
  class Written < StandardError; end

  attr_reader :terminal_out, :terminal_err, :path

  def initialize(dir)
    FileUtils.mkdir_p(dir)
    @path = File.join(dir, "rspec-stray-output-#{Process.pid}.log")
    File.write(@path, '')
    @read_upto = 0
    $stdout.flush
    $stderr.flush
    @terminal_out = $stdout.dup
    @terminal_err = $stderr.dup
    @terminal_out.sync = true
    @terminal_err.sync = true
    $stdout.reopen(@path, 'a')
    $stderr.reopen(@path, 'a')
    $stdout.sync = true
    $stderr.sync = true
  end

  # What was written since the last read, without the allowed lines.
  def written
    $stdout.flush
    $stderr.flush
    text = File.binread(@path, nil, @read_upto) || ''
    @read_upto += text.bytesize
    text.each_line.reject { |line| ALLOWED.each_key.any? { |pattern| pattern.match?(line) } }.join
  end

  def check!(where)
    text = written
    return if text.empty?

    raise Written, "#{where} wrote to stdout or stderr:\n#{text.gsub(/^/, '  ')}\n" \
                   'Check the text with expect { ... }.to output(...).to_stdout (or .to_stderr), ' \
                   'remove the print, or add the line to StrayOutput::ALLOWED with the reason ' \
                   '(spec/stray_output.rb). RSPEC_STRAY_OUTPUT=show turns this check off.'
  end

  # Puts stdout and stderr back, so what runs after the suite (SimpleCov's
  # report, RSpec's summary) reaches the terminal, and removes the file.
  # Returns what was written since the last read.
  def stop
    text = written
    $stdout.reopen(@terminal_out)
    $stderr.reopen(@terminal_err)
    File.delete(@path)
    text
  end
end

if ENV['RSPEC_STRAY_OUTPUT'] != 'show' && !ENV['MUTANT']
  stray_output = StrayOutput.new(File.expand_path('../tmp', __dir__))

  RSpec.configure do |config|
    config.output_stream = stray_output.terminal_out
    config.error_stream = stray_output.terminal_err

    # Output from loading the spec files and booting Rails.
    outside = +''
    config.before(:suite) do
      text = stray_output.written
      outside << "while the spec files loaded:\n#{text}" unless text.empty?
    end

    # Around, not before and after, so the end of the test transaction
    # (rspec-rails' own around hook, which config-level around hooks wrap)
    # counts for its own example. Before the example: what a
    # before(:context) hook or the end of the last group wrote.
    config.around do |example|
      text = stray_output.written
      outside << "before the example at #{example.location}:\n#{text}" unless text.empty?
      example.run
      stray_output.check!("The example at #{example.location}")
    end

    config.after(:suite) do
      text = stray_output.stop
      outside << "after the last example:\n#{text}" unless text.empty?
      unless outside.empty?
        raise StrayOutput::Written, 'Code outside the examples (loading the spec files, a before(:context) or ' \
                                    "after(:context) hook) wrote to stdout or stderr:\n#{outside.gsub(/^/, '  ')}"
      end
    end
  end
end
