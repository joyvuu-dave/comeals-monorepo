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

      # POST /api/v1/reconciliations { "cutoff": "YYYY-MM-DD" }
      #
      # Settles the period: the same thing rake reconciliations:create does
      # nightly, with the cutoff chosen by the caller. Claims the meals,
      # writes the ledger, and refreshes the running balances before it
      # answers; the cook emails go out from a job right after (#71), so
      # the answer does not wait on SMTP. Creating it is the lock — the row
      # and its meals are frozen from this moment, and there is no undo.
      # Preview first.
      def create
        cutoff = Date.iso8601(params.require(:cutoff))
        reconciliation = SettleAndNotify.call(cutoff: cutoff)
        render json: { id: reconciliation.id, date: reconciliation.date.iso8601,
                       cutoff_date: reconciliation.end_date.iso8601,
                       meal_count: reconciliation.number_of_meals },
               status: :created
      rescue Date::Error, ActionController::ParameterMissing
        render json: { message: 'cutoff must be a date, YYYY-MM-DD' }, status: :bad_request
      rescue ActiveRecord::RecordInvalid => e
        render json: { message: e.record.errors.full_messages.to_sentence }, status: :bad_request
      rescue Settlement::Contested, ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
        # Another settlement or a meal write got there first. Nothing was
        # saved; the same request can be sent again.
        render json: { message: 'Someone else was changing these meals at the same time. ' \
                                'Nothing was saved. Try again.' },
               status: :conflict
      end
    end
  end
end
