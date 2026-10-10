# frozen_string_literal: true

require 'securerandom'

# The Idempotency-Key header a bills save (decision 6 of #135) and a guest
# add (S2) need: a new key for each request, or the given one for a
# request sent again. The value is a Structured Field String, so it is in
# quotes.
module IdempotencyKey
  def self.header(key = SecureRandom.uuid)
    { 'Idempotency-Key' => %("#{key}") }
  end
end
