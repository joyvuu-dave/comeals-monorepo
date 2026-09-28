# typed: true
# frozen_string_literal: true

# The guest room booking edit form: GET
# /api/v1/guest-room-reservations/:id, as `{ "event": { ... } }`. The
# fields the form reads and no others, so a new column is not sent until
# someone adds it here (#103). Not GuestRoomReservationSerializer: that
# one builds a calendar chip.
class GuestRoomReservationFormSerializer
  include Alba::Resource

  root_key :event

  attributes :id,
             :resident_id,
             :date
end
