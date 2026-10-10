# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: guest_add_keys
#
#  id          :bigint           not null, primary key
#  key         :text             not null
#  vegetarian  :boolean          not null
#  created_at  :datetime         not null
#  guest_id    :bigint
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_guest_add_keys_on_created_at       (created_at)
#  index_guest_add_keys_on_guest_id         (guest_id)
#  index_guest_add_keys_on_meal_id_and_key  (meal_id,key) UNIQUE
#  index_guest_add_keys_on_resident_id      (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (guest_id => guests.id) ON DELETE => nullify
#  fk_rails_...  (meal_id => meals.id) ON DELETE => cascade
#  fk_rails_...  (resident_id => residents.id) ON DELETE => cascade
#
# The Idempotency-Key of one guest add that was written (S2), by the same
# rules as BillsSaveKey (docs/adr/0009-bills-saves-send-edits.md).
#
# Api::V1::MealsController#create_guest writes the row in the same
# transaction as the guest, under the meal lock, so a row exists exactly
# when that add's guest was written. An add sent again with a key that has
# a row adds nothing: for the same host and flag it is answered as already
# done, with the guest it added, and for another host or flag it is
# refused with 422.
#
# The row records a request, not money. Nothing reads a price from it,
# and the guests stay the source of truth (money rule 8).
class GuestAddKey < ApplicationRecord
  extend T::Sig

  # How long a key is kept, the same as a bills save's key. public/api.md
  # says it. A page sends an add again when the person taps again after
  # no answer, which is seconds or minutes later.
  KEPT_FOR = T.let(7.days, ActiveSupport::Duration)

  belongs_to :meal
  belongs_to :resident
  # Null once the guest was removed. The row stays, so the key still adds
  # nothing (the guest_id foreign key sets it to null).
  belongs_to :guest, optional: true

  # The guest this add made, while it is still a guest of the same host on
  # this meal, or nil. It is nil once that guest was removed, given another
  # host (an admin can do that on the meal form), or moved to another meal.
  # An add sent again with this key is answered with it
  # (GuestReplayedSerializer), and the page shows it in the host's row as
  # the guest the tap asked for.
  sig { returns(T.nilable(Guest)) }
  def guest_as_added
    added = guest
    added if added && added.resident_id == resident_id && added.meal_id == meal_id
  end

  # Deletes the keys made more than KEPT_FOR ago, in one statement by the
  # created_at index, and returns how many it deleted. config/recurring.yml
  # runs it every hour. It runs at SERIALIZABLE beside guest adds, which
  # look up a key and then add one, so the two can refuse each other the
  # way BillsSaveKey.delete_expired and a bills save can. A refused delete
  # is tried again with the tries and waits RecurringJob gives a scheduled
  # job.
  sig { params(now: ActiveSupport::TimeWithZone).returns(Integer) }
  def self.delete_expired(now: Time.current)
    RetryOnConflict.call(attempts: RecurringJob::CONFLICT_ATTEMPTS, base_delay: RecurringJob::CONFLICT_BASE_DELAY) do
      where(created_at: ...(now - KEPT_FOR)).delete_all
    end
  end
end
