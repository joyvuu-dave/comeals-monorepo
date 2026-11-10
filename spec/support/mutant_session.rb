# frozen_string_literal: true

require 'json'
require 'zlib'
require_relative '../../bin/lib/mutant_survivors'

# Writes a mutant session file (.mutant/results/<id>.json.gz) in the shape
# mutant 0.17 writes, holding only the fields bin/lib/mutant_survivors.rb
# reads. Each mutation is a hash: subject, diff, and how it ended
# (:killed, :alive, :timeout, :abort, :neutral_ok, :neutral_failed).
module MutantSession
  PATH_PREFIX = '/home/runner/work/comeals-monorepo/comeals-monorepo/'

  def write_mutant_session(dir, mutations, runtime: 120.0, id: 'session')
    results = File.join(dir, '.mutant', 'results')
    FileUtils.mkdir_p(results)
    subjects = mutations.group_by { |mutation| mutation.fetch(:subject) }.map do |subject, list|
      { 'expression_syntax' => subject,
        'identification' => "#{subject}:#{PATH_PREFIX}#{list.first.fetch(:path, 'app/services/foo.rb:10')}",
        'coverage_results' => list.map { |mutation| coverage_result(mutation) } }
    end
    path = File.join(results, "#{id}.json.gz")
    Zlib::GzipWriter.open(path) { |gz| gz.write(JSON.generate('runtime' => runtime, 'subject_results' => subjects)) }
    path
  end

  # Writes entries (hashes with string keys) into a folder of accepted
  # survivors, each in the file named for its class.
  def write_accepted(dir, entries)
    FileUtils.mkdir_p(dir)
    entries.group_by { |entry| MutantSurvivors.file_for(entry.fetch('subject')) }.each do |name, list|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, list.to_yaml)
    end
  end

  private

  def coverage_result(mutation)
    ended = mutation.fetch(:ended)
    { 'mutation_result' => { 'mutation_type' => ended.to_s.start_with?('neutral') ? 'neutral' : 'evil',
                             'mutation_diff' => mutation.fetch(:diff),
                             'isolation_result' => isolation(ended) },
      'criteria_result' => { 'test_result' => %i[killed neutral_ok].include?(ended),
                             'timeout' => false, 'process_abort' => false } }
  end

  def isolation(ended)
    return { 'timeout' => 600.0, 'process_status' => nil } if ended == :timeout

    { 'timeout' => nil, 'process_status' => { 'exitstatus' => ended == :abort ? 1 : 0 } }
  end
end

RSpec.configure { |config| config.include MutantSession, file_path: %r{spec/(bin|config)/mutant} }
