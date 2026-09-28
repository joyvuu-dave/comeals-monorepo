# typed: true
# frozen_string_literal: true

# The common house booking edit form: GET
# /api/v1/common-house-reservations/:id, as `{ "event": { ... } }`. The
# fields the form reads and no others, so a new column is not sent until
# someone adds it here (#103). Not CommonHouseReservationSerializer: that
# one builds a calendar chip.
class CommonHouseReservationFormSerializer
  include Alba::Resource

  root_key :event

  attributes :id,
             :resident_id,
             :title,
             :start_date,
             :end_date
end
