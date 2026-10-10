# typed: true
# frozen_string_literal: true

# The answer to a guest add whose Idempotency-Key this meal has a row for,
# for the same host and flag (S2): that add was written before, and
# nothing more was added now. Built from the key's row (GuestAddKey).
#
# `guest` is the guest that add made, as stored now, in the same shape as
# the answer to an add that was written (GuestSerializer). It is null when
# that guest was removed since, or given another host, or moved to another
# meal (GuestAddKey#guest_as_added): it is no longer the guest the tap
# asked for. The meal page reads it to tell what the person's second tap
# meant (guestAddAnswered in data_store_guest_adds.ts).
class GuestReplayedSerializer
  include Alba::Resource

  MESSAGE = 'This guest was already added, so nothing more was added.'

  attributes :message, :type

  one :guest_as_added, key: :guest, resource: GuestSerializer

  def message(_key) = MESSAGE

  def type(_key) = 'replayed'
end
