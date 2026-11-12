# frozen_string_literal: true

module Faults
  # Moves the fault suite's server clock (challenge 30). The server loads
  # spec/faults/server_clock.rb, which adds the seconds in this
  # file to Time.now; this side writes them. The clocks of the test
  # process and of PostgreSQL do not move.
  class Clock
    attr_reader :offset

    def initialize(file)
      @file = Pathname(file)
      @offset = 0
    end

    # Seconds to add to the server's real time: forward when above 0.
    def move(seconds)
      FileUtils.mkdir_p(@file.dirname)
      # Written to another file and renamed, so the server never reads half a number.
      temporary = @file.sub_ext('.new')
      temporary.write(seconds.to_s)
      File.rename(temporary, @file)
      @offset = seconds
    end

    def reset = move(0)
  end
end
