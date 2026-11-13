# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# A short real run of bin/faults (challenge 30): its own PostgreSQL, a
# Puma, and the proxy, with every kind of fault at least once and a third
# of the answers to writes lost and sent again. The books must be right
# after, no write saved twice, no write answered with an error after it
# was saved, and no 500 while the database is gone.
RSpec.describe 'bin/faults' do
  # A run takes about a minute. One that goes on longer is stuck, and
  # without a limit it held a CI shard until the job's own limit stopped
  # it, with nothing in the log to say where.
  let(:limit) { 300 }

  # Interrupt first, so the run's own ensure stops its Puma and its
  # PostgreSQL; then kill whatever of the process group is left.
  def stop(waiter)
    Process.kill('INT', waiter.pid)
    return if waiter.join(30)

    Process.kill('KILL', -waiter.pid)
    waiter.join
  end

  def logs
    %w[server_app.log server/server.log].map do |name|
      path = Rails.root.join('tmp/faults', name)
      tail = path.exist? ? path.readlines.last(40).join : "(no file)\n"
      "--- the last lines of tmp/faults/#{name}:\n#{tail}"
    end.join
  end

  it 'keeps the books right and answers every request well while things break' do
    env = { 'FAULTS_SECONDS' => '12', 'FAULTS_CLIENTS' => '6', 'FAULTS_EVERY' => '1', 'FAULTS_LOSE' => '0.3',
            'FAULTS_SEED' => '2' }
    output = +''
    status = Open3.popen2e(env, Rails.root.join('bin/faults').to_s, chdir: Rails.root.to_s,
                                                                    pgroup: true) do |stdin, out, waiter|
      stdin.close
      reader = Thread.new { out.each_line { output << it } }
      unless waiter.join(limit)
        stop(waiter)
        reader.join(5)
        raise "bin/faults ran for more than #{limit} seconds and was stopped.\n#{output}#{logs}"
      end
      reader.join
      waiter.value
    end

    faults = output[/^faults: (.*)$/, 1].to_s
    expect(Faults::Driver::KINDS.map(&:to_s)).to all(satisfy { faults.include?(it) }), output
    expect(output).to include('No problems.'), output.lines.grep_v(%r{\A\s+/}).last(60).join
    expect(status).to be_success
  end
end
