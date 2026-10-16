# frozen_string_literal: true

# EnsureRotationsJob makes rotations until the calendar reaches six
# months ahead. Six months of the default schedule is about seven
# rotations, and the loop reads the community's meals twice for each.
# If the loop is broken and never stops, every example that runs the job
# hangs: it makes rotations forever, or it reads the meals forever and
# makes none. With this context the 31st rotation, or the 201st read of
# the meals, raises an error of its own, so the example fails in seconds
# instead. The examples need a `community`.
RSpec.shared_context 'with a stop for a rotation loop that never ends' do
  before do
    made = 0
    reads = 0
    allow(Community).to receive(:instance).and_return(community)
    allow(community).to receive(:create_next_rotation).and_wrap_original do |original|
      made += 1
      raise 'made more than 30 rotations' if made > 30

      original.call
    end
    allow(community).to receive(:meals).and_wrap_original do |original|
      reads += 1
      raise 'read the meals more than 200 times' if reads > 200

      original.call
    end
  end
end
