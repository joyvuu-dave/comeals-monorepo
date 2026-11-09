# frozen_string_literal: true

# How many inputs the money sweep specs try. The sweep specs try every
# input up to a size, not random ones (issue #269, step 1):
#
#   spec/services/largest_remainder_split_on_every_small_input_spec.rb
#   spec/services/settlement_allocate_to_cents_on_every_small_input_spec.rb
#
# bin/check runs the small size, which takes well under a second. One
# setting changes it:
#
#   MONEY_SWEEP=full  runs the full size, which took 51 seconds on a laptop
#
# Any other value stops the run with an error. Running the small size
# instead would look like a full run that found nothing.
module MoneySweep
  NAME = 'MONEY_SWEEP'
  SIZES = %w[small full].freeze

  def self.size(env: ENV)
    value = env.fetch(NAME, 'small')
    return value.to_sym if SIZES.include?(value)

    raise ArgumentError, "#{NAME} must be one of #{SIZES.join(', ')}; got #{value.inspect}"
  end

  # Every list of `length` numbers, each taken from `values`, for every
  # length in `lengths`. Built one at a time, so the full size does not
  # hold millions of lists in memory.
  def self.each_list(lengths, values, &)
    return enum_for(:each_list, lengths, values) unless block_given?

    lengths.each do |length|
      values.to_a.repeated_permutation(length, &)
    end
  end

  # Checking millions of inputs with one `expect` each would be slow, and
  # one failure would be lost among the others. A sweep collects what it
  # finds here and the spec expects the list to be empty. It keeps the
  # first few failures, which is enough to see the pattern, and counts
  # the rest.
  class Failures
    KEEP = 20

    attr_reader :count

    def initialize
      @kept = []
      @count = 0
    end

    def add(message)
      @count += 1
      @kept << message if @kept.size < KEEP
    end

    def to_s
      return 'none' if @count.zero?

      more = @count > KEEP ? "\n... and #{@count - KEEP} more" : ''
      "#{@count} failures:\n#{@kept.join("\n")}#{more}"
    end
  end
end
