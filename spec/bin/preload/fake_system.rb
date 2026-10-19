# frozen_string_literal: true

require 'json'

# For a Ruby script that runs outside commands with Kernel#system
# (bin/setup). Each call is written to the log file named by
# FAKE_SYSTEM_LOG and runs nothing. FAKE_SYSTEM_ANSWERS is a JSON object
# from each command the spec expects to its answer, true or false. A
# command it does not list stops the script, so nothing real can run.
class Object
  private

  def system(*args)
    command = args.join(' ')
    File.write(ENV.fetch('FAKE_SYSTEM_LOG'), "#{command}\n", mode: 'a')
    answers = JSON.parse(ENV.fetch('FAKE_SYSTEM_ANSWERS'))
    abort("fake system: no answer for #{command}") unless answers.key?(command)
    answers.fetch(command)
  end
end
