# typed: strict
# frozen_string_literal: true

# One guest add's request (POST /api/v1/meals/:meal_id/residents/
# :resident_id/guests): its host, its vegetarian flag and its
# Idempotency-Key (S2), each read once. Api::V1::MealsController#create_guest
# asks it what is wrong with the request, which key row of the meal it
# matches, and has it write the guest with its key's row.
#
# The key works the way a bills save's does (BillsSaveKey, ADR 0009): the
# page sends one new key with each add, and the same key when a tap sends
# an add that got no answer again. A key the meal has a row for adds
# nothing.
class GuestAdd
  extend T::Sig

  # The words for an add with no Idempotency-Key header. A meal page
  # loaded before guest adds took a key sends none, and shows these words
  # to the person. A resident does not know what a header is, so the
  # sentences for them come first, and the last one is for other API
  # clients.
  KEY_MISSING = T.let('This page is out of date. Nothing was saved. Reload the page and add the guest again. ' \
                      'A guest add needs an Idempotency-Key header, with a new key for each guest.',
                      String)
  # The answer to a key the meal has a row for, with another host or flag
  # (Api::V1::MealsController#seen_guest_key_answer). The answer for the
  # same add is GuestReplayedSerializer::MESSAGE.
  KEY_REUSED = T.let('This Idempotency-Key was already used for a different guest add. ' \
                     'Nothing was saved. Send a new key with each guest add.', String)

  sig { params(params: ActionController::Parameters, key_header: T.nilable(String)).void }
  def initialize(params, key_header)
    @host_id = T.let(params[:resident_id], T.untyped)
    @flags = T.let(TrueOrFalse.from_params(params, %i[vegetarian], required: true),
                   T.any(T::Hash[Symbol, T::Boolean], String))
    @key_header = T.let(IdempotencyKeyHeader.new(key_header, missing: KEY_MISSING), IdempotencyKeyHeader)
  end

  # Why the add cannot be written, for a 400: a missing or wrong key
  # first, then a wrong flag. nil when it can be.
  sig { returns(T.nilable(String)) }
  def error
    flags = @flags
    @key_header.error || (flags if flags.is_a?(String))
  end

  # The meal's row for this add's key, or nil. An add with an error is not
  # looked up, so it gets the other checks, in their usual order.
  sig { params(meal: Meal).returns(T.nilable(GuestAddKey)) }
  def seen_key(meal)
    return nil if error

    GuestAddKey.find_by(meal_id: meal.id, key: @key_header.key)
  end

  # True when the key's row is for this same add: the same host and the
  # same flag. The host in the path is read the way the guest's
  # resident_id reads it, so "010" is host 10.
  sig { params(seen: GuestAddKey).returns(T::Boolean) }
  def same_add?(seen)
    seen.resident_id == GuestAddKey.type_for_attribute(:resident_id).cast(@host_id) && seen.vegetarian == vegetarian
  end

  # Writes the guest, then its key's row, and returns the guest. The
  # caller runs this under the meal lock, in one transaction, so a guest
  # the model refuses leaves no key, and a try that is rolled back takes
  # its guest and its key together. Raises the way save! does.
  sig { params(meal: Meal).returns(Guest) }
  def write(meal)
    # multiplier omitted intentionally — DB default of 2 applies (adult guest).
    guest = Guest.new(meal_id: meal.id, resident_id: @host_id, vegetarian: vegetarian)
    guest.save!
    GuestAddKey.create!(meal: meal, key: T.must(@key_header.key), resident: guest.resident, vegetarian: vegetarian,
                        guest: guest)
    guest
  end

  private

  sig { returns(T::Boolean) }
  def vegetarian
    T.cast(@flags, T::Hash[Symbol, T::Boolean]).fetch(:vegetarian)
  end
end
