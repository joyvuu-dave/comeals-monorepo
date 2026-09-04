# frozen_string_literal: true

require 'rails_helper'

# The sigs on LedgerVerification are checked when the code runs, in this
# suite and in production (docs/sorbet.md, "Runtime behaviour"). Runtime
# type checks only.
RSpec.describe LedgerVerification do
  it 'refuses to summarize anything but a LedgerCheckRun' do
    expect { described_class.summary_for(JobRun.new) }.to raise_error(TypeError, /run/)
  end

  it 'refuses a mismatch error built without its run' do
    expect { described_class::MismatchError.new(nil) }.to raise_error(TypeError, /run/)
  end
end
