# typed: true
# frozen_string_literal: true

module Api
  module V1
    class GuestRoomReservationsController < ApiController
      before_action :authenticate
      before_action :set_resource, only: %i[show update destroy]

      # GET /api/v1/guest-room-reservations/:id
      # Hosts are served separately by CommunitiesController#hosts and cached
      # in the frontend store (DataStore.hosts) so open modals stay in sync
      # via Pusher without per-modal refetches. Don't inline the list here.
      def show
        render json: { event: @grr }
      end

      # POST /api/v1/guest-room-reservations/create
      def create
        grr = GuestRoomReservation.new(resident_id: params[:resident_id], date: params[:date])
        render_retrying_on_conflict do
          if grr.save
            { json: { message: 'Guest Room Reservation has been created' } }
          else
            { json: { message: grr.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
      end

      # PATCH /api/v1/guest-room-reservations/:id/update
      def update
        render_retrying_on_conflict do
          if @grr.update(date: params[:date], resident_id: params[:resident_id])
            { json: { message: 'Guest Room Reservation has been updated' } }
          else
            { json: { message: @grr.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
      end

      # DELETE /api/v1/guest-room-reservations/:id/delete
      def destroy
        render_retrying_on_conflict do
          @grr.destroy!
          { json: { message: 'Guest Room Reservation has been removed' } }
        end
      end

      private

      def set_resource
        @grr = GuestRoomReservation.find_by(id: params[:id])

        not_found_api if @grr.blank?
      end
    end
  end
end
