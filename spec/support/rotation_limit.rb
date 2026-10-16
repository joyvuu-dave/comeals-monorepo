# frozen_string_literal: true

# EnsureRotationsJob makes rotations until the calendar reaches six
# months ahead. Six months of the default schedule is about seven
# rotations. If the loop's check is broken and never stops it, every
# example that runs the job makes rotations forever and hangs. With
# this context the 31st rotation raises an error of its own, so the
# example fails in seconds instead. The examples need a `community`.
RSpec.shared_context 'with at most 30 rotations made' do
  before do
    made = 0
    allow(Community).to receive(:instance).and_return(community)
    allow(community).to receive(:create_next_rotation).and_wrap_original do |original|
      made += 1
      raise 'made more than 30 rotations' if made > 30

      original.call
    end
  end
end
