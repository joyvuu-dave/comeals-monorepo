# frozen_string_literal: true

require 'open3'

module DeployWatch
  # Runs one outside command with a time limit, in a process group of its
  # own, so a hung heroku or psql under it can be stopped. Its input goes
  # through a pipe: a secret on the command line could be read with ps.
  module Shell
    Result = Struct.new(:ok, :out, :error)

    POLL = 0.2
    # The process groups running now, so a stopped watch can end them.
    RUNNING = {}
    LOCK = Mutex.new

    module_function

    def run(*command, timeout:, input: '')
      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, process|
        LOCK.synchronize { RUNNING[process.pid] = true }
        send_input(stdin, input)
        out = Thread.new { text(stdout.read) }
        err = Thread.new { text(stderr.read) }
        finish(process, out, err, Time.now + timeout, timeout)
      end
    rescue SystemCallError => e
      Result.new(false, '', e.message)
    end

    def stop_all
      LOCK.synchronize { RUNNING.keys }.each { |pid| stop_group(pid) }
    end

    def stop_group(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def text(bytes)
      bytes.force_encoding('UTF-8').scrub
    end

    # In a thread that nobody joins: a command that ends without reading its
    # input makes the write fail, and that changes nothing here.
    def send_input(stdin, input)
      writer = Thread.new do
        stdin.write(input)
        stdin.close
      end
      writer.report_on_exception = false
    end

    def finish(process, out, err, deadline, timeout)
      sleep(POLL) while process.alive? && Time.now < deadline
      if process.alive?
        stop_group(process.pid)
        out.kill
        err.kill
        return Result.new(false, '', "no answer after #{timeout} s")
      end
      Result.new(process.value.success?, out.value, last_line(err.value))
    ensure
      LOCK.synchronize { RUNNING.delete(process.pid) }
    end

    # The last line that is not blank, where psql and the Heroku CLI put the
    # error.
    def last_line(text)
      text.lines.map(&:strip).reject(&:empty?).last.to_s
    end
  end
end
