# frozen_string_literal: true

module Api
  module V1
    class RotationsController < ApiController
      before_action :authenticate
      before_action :set_resource, only: [:show]

      # GET /api/v1/rotations/:id
      def show
        render json: RotationLogSerializer.new(@rotation, params: { cook_ids: @rotation.cook_ids })
      end

      private

      def set_resource
        @rotation = Rotation.find_by(id: params[:id])

        not_found_api if @rotation.blank?
      end
    end
  end
end
