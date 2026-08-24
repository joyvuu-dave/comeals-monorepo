# frozen_string_literal: true

module Api
  module V1
    class ReconciliationsController < ApiController
      before_action :authenticate

      # GET /api/v1/reconciliations/preview?cutoff=YYYY-MM-DD
      #
      # What a settlement at that cutoff would claim and store, without
      # writing anything. The cutoff must be a past day, like the settlement
      # itself requires. No meals to settle is a valid answer, not an error:
      # the lists come back empty.
      def preview
        cutoff = Date.iso8601(params.require(:cutoff))
        preview = Settlement.preview(cutoff: cutoff)
        render json: ReconciliationPreviewSerializer.new(preview)
      rescue Date::Error, ActionController::ParameterMissing
        render json: { message: 'cutoff must be a date, YYYY-MM-DD' }, status: :bad_request
      rescue Settlement::InvalidCutoff => e
        render json: { message: e.message }, status: :bad_request
      end
    end
  end
end
