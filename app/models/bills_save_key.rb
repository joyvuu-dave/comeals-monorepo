# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: bills_save_keys
#
#  id           :bigint           not null, primary key
#  edits_sha256 :text             not null
#  key          :text             not null
#  created_at   :datetime         not null
#  meal_id      :bigint           not null
#
# Indexes
#
#  index_bills_save_keys_on_created_at       (created_at)
#  index_bills_save_keys_on_meal_id_and_key  (meal_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id) ON DELETE => cascade
#
# The Idempotency-Key of one bills save that was written (decision 6 of
# #135, docs/adr/0009-bills-saves-send-edits.md).
#
# Api::V1::MealsController#save_bills writes the row in the same
# transaction as the bills, under the meal lock, so a row exists exactly
# when that save's bills were written. A save sent again with a key that
# has a row writes nothing: with the same edits it is answered as already
# made, and with other edits it is refused with 422.
#
# The row records a request, not money. Nothing reads an amount from it,
# and the bills stay the source of truth (money rule 8).
class BillsSaveKey < ApplicationRecord
  extend T::Sig

  # How long a key is kept. The IETF draft asks the server to publish
  # this; public/api.md says it. A page sends a save again within seconds
  # of the first try, so a week is far more than it needs.
  KEPT_FOR = T.let(7.days, ActiveSupport::Duration)

  belongs_to :meal

  # Deletes the keys made more than KEPT_FOR ago, in one statement by the
  # created_at index, and returns how many it deleted. config/recurring.yml
  # runs it every hour. Not inside a bills save, so a save writes only its
  # own meal's bills and its own key.
  #
  # The delete runs at SERIALIZABLE, and so does a bills save, which looks
  # up its key and then adds one. While the table is small, PostgreSQL
  # reads all of it for that look-up, so the two can conflict. Most often
  # the save is the one refused, and RetryOnConflict runs it again. If a
  # save commits while this statement runs, the delete is the one refused,
  # so it is tried again too, with the tries and waits RecurringJob gives
  # a scheduled job.
  sig { params(now: ActiveSupport::TimeWithZone).returns(Integer) }
  def self.delete_expired(now: Time.current)
    RetryOnConflict.call(attempts: RecurringJob::CONFLICT_ATTEMPTS, base_delay: RecurringJob::CONFLICT_BASE_DELAY) do
      where(created_at: ...(now - KEPT_FOR)).delete_all
    end
  end
end
