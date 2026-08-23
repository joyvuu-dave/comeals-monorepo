# frozen_string_literal: true

# The rotation page: one rotation, and every resident with a flag that
# says whether they signed up to cook in it. Build it with
# `params: { cook_ids: rotation.cook_ids }`.
class RotationLogSerializer
  include Alba::Resource

  class ResidentSerializer
    include Alba::Resource

    attributes :id,
               :display_name,
               :signed_up

    def display_name(resident)
      "#{resident.unit.name} - #{resident.name}"
    end

    def signed_up(resident)
      params.fetch(:cook_ids).include?(resident.id)
    end
  end

  # `id` is the database id, the one in the URL. `place_value` is the
  # number people see: the rotation's position in date order, the same
  # number the calendar bar shows.
  attributes :id,
             :place_value,
             :description

  # Every resident who can be asked to cook, not only the ones signed up.
  # The log is a sign-up sheet: each row says whether that person has a
  # bill on one of this rotation's meals.
  attribute :residents do |_rotation|
    ResidentSerializer.new(Resident.eligible_cooks.includes(:unit), params: params).to_h
  end
end
