# frozen_string_literal: true

require 'rails_helper'

# The sigs on BalanceRecalculation and SnapshotRead are checked when the
# code runs, in this suite and in production (docs/sorbet.md, "Runtime
# behaviour"). Runtime type checks only.
RSpec.describe BalanceRecalculation do
  it 'refuses anything but a Community' do
    expect { described_class.call(community: Unit.new) }.to raise_error(TypeError, /community/)
  end

  it 'refuses a snapshot read with no block to run' do
    expect { SnapshotRead.call }.to raise_error(TypeError, /blk/)
  end
end
