# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# The fault suite (challenge 30) moves the server's clock in the middle of
# a storm. The server is another process, so the clock is moved through
# a file: the server loads spec/faults/server_clock.rb, and
# Faults::Clock writes how far to move it.
RSpec.describe Faults::Clock do
  let(:file) { Rails.root.join('tmp/faults/clock_spec/offset') }
  let(:clock) { described_class.new(file) }

  # A Ruby process that loads the server's side, prints Time.now each
  # time it reads a line, and stops at the end of its input.
  def server_times(*offsets)
    script = '$stdout.sync = true; while $stdin.gets; puts Time.now.to_f; end'
    Open3.popen2({ 'FAULTS_CLOCK_FILE' => file.to_s }, RbConfig.ruby, '-r',
                 Rails.root.join('spec/faults/server_clock.rb').to_s, '-e', script) do |input, output|
      offsets.map do |offset|
        clock.move(offset) unless offset.nil?
        input.puts
        Float(output.gets) - Process.clock_gettime(Process::CLOCK_REALTIME)
      end
    end
  end

  before { clock.reset }

  it "moves the server's clock forward and back, and puts it right" do
    off, forward, back, right = server_times(nil, 3600, -86_400, 0)
    expect(off).to be_within(1).of(0)
    expect(forward).to be_within(1).of(3600)
    expect(back).to be_within(1).of(-86_400)
    expect(right).to be_within(1).of(0)
  end

  it 'leaves the clock alone in a process that did not load the server side' do
    clock.move(3600)
    expect(Time.now.to_f).to be_within(1).of(Process.clock_gettime(Process::CLOCK_REALTIME))
  end
end
