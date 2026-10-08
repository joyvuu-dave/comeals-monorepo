# frozen_string_literal: true

require 'bigdecimal'

# The edits a bills save sends (#135) to turn the bills a page saw into
# the bills it wants: one add, change or remove for each cook whose bill
# differs, and nothing for a cook whose bill stays the same. Bills are
# { resident_id => { amount: BigDecimal, no_cost: true or false } }.
#
# The random action sequences (spec/requests/api/v1/meal_random_actions_spec.rb)
# and the storm clients (spec/support/storm/client.rb) build their saves
# with it, the way the page does.
module BillEdits
  def self.between(seen, wanted)
    (seen.keys | wanted.keys).sort.filter_map do |id|
      from = seen[id]
      to = wanted[id]
      next if from == to

      if from.nil? then { op: 'add', resident_id: id, to: wire(to) }
      elsif to.nil? then { op: 'remove', resident_id: id, from: wire(from) }
      else { op: 'change', resident_id: id, from: wire(from), to: wire(to) }
      end
    end
  end

  # Amounts go as text, never as a JSON number.
  def self.wire(values)
    { amount: values[:amount].to_s('F'), no_cost: values[:no_cost] }
  end

  # The Idempotency-Key header a bills save needs (decision 6 of #135):
  # a new key for each save, or the given one for a save sent again. The
  # value is a Structured Field String, so it is in quotes.
  def self.key_header(key = SecureRandom.uuid)
    { 'Idempotency-Key' => %("#{key}") }
  end
end
