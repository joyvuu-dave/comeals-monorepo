# frozen_string_literal: true

module Faults
  # Wraps a storm transport (challenge 30) so that some answers to writes
  # are lost: the server got the request and answered, but the answer
  # never reached the phone. The phone then sends the same request again,
  # with the same headers and body (the same Idempotency-Key, the same
  # version), and the client sees only the answer to that second send.
  #
  # Every lost answer is recorded with the answer the phone never saw and
  # the answer to the second send. Faults::Report reads them.
  class LossyTransport
    Resend = Data.define(:verb, :path, :first_status, :second_status, :first_body, :second_body)

    WRITES = %i[post patch put delete].freeze

    attr_reader :resends

    def initialize(transport, chance:, seed:)
      @transport = transport
      @chance = chance
      @rng = Random.new(seed)
      @lock = Mutex.new
      @resends = []
    end

    def call(method, path, headers, body, ip)
      status, response = @transport.call(method, path, headers, body, ip)
      return [status, response] unless WRITES.include?(method) && lose?

      second_status, second_body = @transport.call(method, path, headers, body, ip)
      resend = Resend.new(method, path, status, second_status, response.to_s[0, 300], second_body.to_s[0, 300])
      @lock.synchronize { @resends << resend }
      [second_status, second_body]
    end

    private

    def lose? = @lock.synchronize { @rng.rand < @chance }
  end
end
