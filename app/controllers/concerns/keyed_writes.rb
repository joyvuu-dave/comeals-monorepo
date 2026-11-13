# typed: true
# frozen_string_literal: true

# An Idempotency-Key on a calendar write or a settlement (challenge 30,
# docs/adr/0015-idempotency-keys-on-calendar-writes.md). The header is read
# by the IETF draft's rules (IdempotencyKeyHeader).
#
#   Idempotency-Key: "8e03978e-40d5-43e8-bc93-6894a57f9324"
#
# A phone that sends a write and loses the answer cannot tell whether the
# write was saved, and sends it again with the same key. The checks, in
# order, in the before_action answer_if_request_key_seen. Each controller
# names it for its writes, before any other before_action that can answer
# (set_resource's 404 for a record the first send deleted):
#
#   1. No header: the write runs as it always has. A page loaded before
#      keys were added sends none.
#   2. A header that is not a key: 400, and nothing is saved.
#   3. A key this sender has a row for, from the same request: the stored
#      answer, with the header Idempotent-Replayed: true. Nothing is saved.
#   4. A key this sender has a row for, from another request: 422.
#
# Otherwise the write runs, and when its answer is a 2xx, the key's row is
# written in the same transaction (keyed). The transaction looks the key up
# again first: two sends with the same key at the same moment both pass
# step 3, and the one that commits second is refused by PostgreSQL as a
# conflict, because it read the key the first one wrote. RetryOnConflict
# runs it again, and the lookup finds the row
# (spec/requests/api/v1/request_key_race_spec.rb).
module KeyedWrites
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApiController }

  REPLAYED = 'Idempotent-Replayed'

  private

  # A calendar write (an event, a reservation), tried again when PostgreSQL
  # refuses it for a conflict with another transaction, and answered 409
  # when the conflict does not go away (ADR 0005), with its
  # Idempotency-Key when it has one (keyed). The block does the write
  # and returns the render arguments; nothing renders inside it, because a
  # retry runs it again. A reservation checks that its period is free and
  # then inserts — a read before a write, which is exactly what SERIALIZABLE
  # refuses when two of them race — and before this the refusal was a 500
  # (spec/requests/api/v1/calendar_writes_retry_spec.rb).
  def render_retrying_on_conflict(&)
    render(**RetryOnConflict.call { keyed(&) })
  rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
    render json: { message: 'Someone else was changing the calendar at the same time. ' \
                            'Nothing was saved. Try again.' },
           status: :conflict
  end

  def answer_if_request_key_seen
    value = request.headers['Idempotency-Key']
    return if value.nil?

    header = IdempotencyKeyHeader.new(value)
    return render(json: { message: header.error }, status: :bad_request) if header.key.nil?

    @request_key = header.key
    seen = seen_request_key
    render(**seen) if seen
  end

  # The answer for a key this sender already has a row for, or nil. nil
  # too for a request with no key.
  def seen_request_key
    return nil if @request_key.nil?

    row = RequestKey.find_by(sender: RequestKey.sender_of(T.must(current_login)), key: @request_key)
    return nil if row.nil?
    return { json: { message: RequestKey::OTHER_REQUEST }, status: :unprocessable_content } if
      row.request_sha256 != RequestKey.request_sha256(request)

    response.set_header(REPLAYED, 'true')
    { json: row.body, status: row.status }
  end

  # Runs a write that returns its render arguments. With a key, the write
  # and the key's row are one transaction; the caller retries it.
  def keyed
    return yield if @request_key.nil?

    ActiveRecord::Base.transaction do
      seen_request_key || yield.tap { |rendering| keep_request_key(rendering) }
    end
  end

  # Writes the key's row, for a request with a key whose answer saved
  # something. The caller runs it in the write's transaction.
  def keep_request_key(rendering)
    return if @request_key.nil?

    status = Rack::Utils.status_code(rendering.fetch(:status, :ok))
    return unless (200..299).cover?(status)

    RequestKey.create!(sender: RequestKey.sender_of(T.must(current_login)), key: @request_key,
                       request_sha256: RequestKey.request_sha256(request), status: status,
                       body: JSON.parse(rendering.fetch(:json).to_json))
  end
end
