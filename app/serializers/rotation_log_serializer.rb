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

  attributes :id,
             :description

  many :residents, resource: ResidentSerializer

  def id(rotation)
    rotation.place_value
  end
end
