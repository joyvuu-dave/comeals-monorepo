# frozen_string_literal: true

module Api
  module V1
    class CommonHouseReservationsController < ApiController
      before_action :authenticate
      before_action :set_resource, only: %i[show update destroy]

      # GET /api/v1/common-house-reservations?start_date=123
      def index
        chrs = if params[:start].present? && params[:end].present?
                 CommonHouseReservation.includes({ resident: :unit })
                                       .where(start_date: (params[:start])..)
                                       .where(start_date: ..(params[:end]))
               else
                 CommonHouseReservation.includes({ resident: :unit }).all
               end

        render json: CommonHouseReservationSerializer.new(chrs)
      end

      # GET /api/v1/common-house-reservations/:id
      # Residents are served separately by CommunitiesController#hosts and
      # cached in the frontend store (DataStore.hosts) so open modals stay
      # in sync via Pusher without per-modal refetches.
      def show
        render json: { event: @chr }
      end

      # POST /api/v1/common-house-reservations
      # { resident_id, start_year, start_month, start_day,
      #   start_hours, start_minutes, end_hours, end_minutes, title }
      def create
        times = parse_start_end_params
        return render_invalid_date unless times

        chr = CommonHouseReservation.new(resident_id: params[:resident_id], start_date: times[:start_date],
                                         end_date: times[:end_date], community: Community.instance,
                                         title: params[:title])
        if chr.save
          render json: { message: 'Common House Reservation has been created' }
        else
          render json: { message: chr.errors.full_messages.join("\n") }, status: :bad_request
        end
      end

      # PATCH /api/v1/common-house-reservations/:id/update
      def update
        times = parse_start_end_params
        return render_invalid_date unless times

        if @chr.update(start_date: times[:start_date], end_date: times[:end_date], resident_id: params[:resident_id],
                       title: params[:title])
          render json: { message: 'Common House Reservation has been updated' }
        else
          render json: { message: @chr.errors.full_messages.join("\n") }, status: :bad_request
        end
      end

      # DELETE /api/v1/common-house-reservations/:id/delete
      def destroy
        @chr.destroy!

        render json: { message: 'Common House Reservation has been removed' }
      end

      private

      def set_resource
        @chr = CommonHouseReservation.find_by(id: params[:id])

        not_found_api if @chr.blank?
      end
    end
  end
end
