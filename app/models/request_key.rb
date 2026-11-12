# typed: strict
# frozen_string_literal: true

# The Idempotency-Key of one calendar write or settlement that was saved
# (challenge 30, docs/adr/0015-idempotency-keys-on-calendar-writes.md),
# with the answer the write got.
#
# KeyedWrites writes the row in the same transaction as the write, so a
# row exists exactly when that write was saved. A write sent again with a
# key that has a row writes nothing: with the same request it gets the
# stored answer, and with another request it is refused with 422.
#
# Only an answer that saved something is kept (2xx). A refused write
# saved nothing, so it is safe to send again and is worked out again.
#
# The row records a request, not money. Nothing reads an amount from it
# (money rule 8).
# == Schema Information
#
# Table name: request_keys
#
#  id             :bigint           not null, primary key
#  body           :jsonb            not null
#  key            :text             not null
#  request_sha256 :text             not null
#  sender         :text             not null
#  status         :integer          not null
#  created_at     :datetime         not null
#
# Indexes
#
#  index_request_keys_on_created_at      (created_at)
#  index_request_keys_on_sender_and_key  (sender,key) UNIQUE
#
class RequestKey < ApplicationRecord
  extend T::Sig

  # How long a key is kept, the same as a bills save's key. public/api.md
  # says it. A page sends a write again within seconds or minutes.
  KEPT_FOR = T.let(7.days, ActiveSupport::Duration)

  OTHER_REQUEST = T.let('This Idempotency-Key was already used for a different request. ' \
                        'Send a new key with each new change. Nothing was saved.', String)

  # Parameters that are not part of the change. The token says who sent
  # it (the sender column), and the two push fields name the browser's
  # Pusher connection, which can be new by the time the page sends again.
  NOT_THE_CHANGE = T.let(%w[token socket_id push_token controller action format].freeze, T::Array[String])

  # "Resident:12" or "CommonHouseLogin:1".
  sig { params(login: JwtAuth::Login).returns(String) }
  def self.sender_of(login)
    "#{login.class.name}:#{login.id}"
  end

  # The hash of what the request asks for: its method, its path, and its
  # parameters with their keys sorted, so the order a client sends them
  # in does not change it.
  #
  # The parameters are read from the body and the query string as sent,
  # not from request_parameters. Rails' params wrapper adds a copy of the
  # body under the model's name there, and which fields it copies depends
  # on whether the model's columns were loaded yet, so two sends of one
  # request could hash differently (spec/requests/api/v1/request_key_race_spec.rb).
  sig { params(request: ActionDispatch::Request).returns(String) }
  def self.request_sha256(request)
    sent = sent_body(request).merge(Rack::Utils.parse_nested_query(request.query_string))
    # T.unsafe: Sorbet cannot check a splat of an array whose size it does not know.
    change = sorted(T.unsafe(sent).except(*NOT_THE_CHANGE))
    Digest::SHA256.hexdigest("#{request.request_method} #{request.path}\n#{JSON.generate(change)}")
  end

  # Rails has already parsed the body by now, so JSON that does not parse
  # has been answered 400 before this runs.
  sig { params(request: ActionDispatch::Request).returns(T::Hash[String, T.untyped]) }
  def self.sent_body(request)
    raw = request.raw_post.to_s
    return {} if raw.empty?

    body = request.media_type == 'application/json' ? JSON.parse(raw) : Rack::Utils.parse_nested_query(raw)
    body.is_a?(Hash) ? body : { '_json' => body }
  end
  private_class_method :sent_body

  sig { params(value: T.untyped).returns(T.untyped) }
  def self.sorted(value)
    case value
    when Hash then value.sort_by { |name, _| name.to_s }.to_h { |name, inner| [name.to_s, sorted(inner)] }
    when Array then value.map { |inner| sorted(inner) }
    else value
    end
  end
  private_class_method :sorted

  # Deletes the keys made more than KEPT_FOR ago, in one statement by the
  # created_at index, and returns how many it deleted. config/recurring.yml
  # runs it every hour. A keyed write looks up its key and then adds one at
  # SERIALIZABLE, so the two can refuse each other the way
  # BillsSaveKey.delete_expired and a bills save can. A refused delete is
  # tried again with the tries and waits RecurringJob gives a scheduled
  # job.
  sig { params(now: ActiveSupport::TimeWithZone).returns(Integer) }
  def self.delete_expired(now: Time.current)
    RetryOnConflict.call(attempts: RecurringJob::CONFLICT_ATTEMPTS, base_delay: RecurringJob::CONFLICT_BASE_DELAY) do
      where(created_at: ...(now - KEPT_FOR)).delete_all
    end
  end
end
