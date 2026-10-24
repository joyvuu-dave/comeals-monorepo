# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# spec/stray_output.rb points stdout and stderr at a file for the whole
# run. These examples start a second one inside it, write the ways a spec
# can write, and stop it, which gives stdout and stderr back to the first.
# Printing is what these examples test.
# rubocop:disable-next RSpec/Output
RSpec.describe StrayOutput do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  # What was written while the block ran.
  def capture
    stray = described_class.new(dir)
    begin
      yield stray
    ensure
      text = stray.stop
    end
    text
  end

  it 'sees a puts, a warning, a child process, and a write to fd 2 that skips $stderr, as C code does' do
    text = capture do
      puts 'from puts'
      warn 'from warn'
      system('echo from a child')
      IO.for_fd(2, autoclose: false).syswrite("from fd 2\n")
    end

    expect(text).to eq("from puts\nfrom warn\nfrom a child\nfrom fd 2\n")
  end

  it 'sees nothing that the output matchers took' do
    text = capture do
      expect { puts 'x' }.to output("x\n").to_stdout
      expect { system('echo y') }.to output("y\n").to_stdout_from_any_process
    end

    expect(text).to eq('')
  end

  it 'fails the check with the text and the place, and reads each part once' do
    capture do |stray|
      puts 'stray line'

      expect { stray.check!('The example at x:1') }
        .to raise_error(StrayOutput::Written, /\AThe example at x:1 wrote to stdout or stderr:\n  stray line\n/)
      expect { stray.check!('The example at x:2') }.not_to raise_error
    end
  end

  it 'puts stdout back and removes its file when it stops' do
    stray = described_class.new(dir)
    path = stray.path
    stray.stop

    expect { puts 'after' }.to output("after\n").to_stdout
    expect(File).not_to exist(path)
  end
end
