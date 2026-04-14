# frozen_string_literal: true

module Api
  module V1
    class RotationsController < ApiController
      before_action :authenticate
      before_action :set_resource, only: [:show]

      # GET /api/v1/rotations
      def index
        if params[:start].present? && params[:end].present?
          rotation_ids = Meal.where(date: (params[:start])..)
                             .where(date: ..(params[:end]))
                             .where.not(rotation_id: nil)
                             .pluck(:rotation_id).uniq
          rotations = Rotation.find(rotation_ids)
        else
          rotations = Rotation.all
        end

        render json: rotations
      end

      # GET /api/v1/rotations/:id
      def show
        render json: @rotation, cook_ids: @rotation.cook_ids, serializer: RotationLogSerializer
      end

      private

      def authenticate
        not_authenticated_api unless signed_in_resident_api?
      end

      def set_resource
        @rotation = Rotation.includes({ residents: :unit }).find_by(id: params[:id])

        not_found_api if @rotation.blank?
      end
    end
  end
end
