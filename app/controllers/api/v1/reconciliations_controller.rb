# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class ReconciliationsController < ApiController
      extend T::Sig

      include KeyedWrites

      before_action :authenticate, :require_reconciler
      before_action :answer_if_request_key_seen, only: [:create]

      # GET /api/v1/reconciliations/preview?cutoff=YYYY-MM-DD
      #
      # What a settlement at that cutoff would claim and store, without
      # writing anything. The cutoff must be at least 14 days before today,
      # like the settlement itself requires (ADR 0011 rule 2). No meals to
      # settle is a valid answer, not an error: the lists come back empty.
      # A cutoff not written as YYYY-MM-DD (YearMonthDay) is a 400.
      sig { void }
      def preview
        cutoff = YearMonthDay.parse(params.require(:cutoff))
        preview = Settlement.preview(cutoff: cutoff)
        render json: ReconciliationPreviewSerializer.new(preview)
      rescue Date::Error, ActionController::ParameterMissing
        render json: { message: 'cutoff must be a date, YYYY-MM-DD' }, status: :bad_request
      rescue Settlement::InvalidCutoff => e
        render json: { message: e.message }, status: :bad_request
      end

      # POST /api/v1/reconciliations { "cutoff": "YYYY-MM-DD" }
      #
      # Settles the period: the same thing the admin form's Create and
      # rake reconciliations:create (run by hand) do, with the cutoff chosen
      # by the caller. Claims the meals,
      # writes the ledger, and refreshes the running balances before it
      # answers; the cook emails go out from a job right after (#71), so
      # the answer does not wait on SMTP. Creating it is the lock — the row
      # and its meals are frozen from this moment, and there is no undo.
      # Preview first.
      #
      # The answer is built from what the settlement read inside its own
      # transaction, with no query after the commit. A query here could be
      # refused, and the 409 below would then say "Nothing was saved"
      # about a settlement that is saved
      # (spec/requests/no_query_after_commit_spec.rb).
      sig { void }
      def create
        cutoff = YearMonthDay.parse(params.require(:cutoff))
        # A person is waiting, so three quick tries and then the 409 below,
        # not the rake task's minutes of waiting (SettleAndNotify::REQUEST).
        # The Idempotency-Key, when the request has one, is written in the
        # settlement's transaction, with the answer (KeyedWrites).
        answer = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))
        SettleAndNotify.call(cutoff: cutoff, retries: SettleAndNotify::REQUEST,
                             also: ->(settlement) { keep_request_key(answer = created(settlement)) })
        render(**T.must(answer))
      rescue Date::Error, ActionController::ParameterMissing
        render json: { message: 'cutoff must be a date, YYYY-MM-DD' }, status: :bad_request
      rescue ActiveRecord::RecordInvalid => e
        render(**(seen_request_key || { json: { message: in_the_callers_words(e.record.errors) },
                                        status: :bad_request }))
      rescue Settlement::Contested, ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
        # Another settlement or a meal write got there first. Nothing was
        # saved; the same request can be sent again. The one that got
        # there first may be this request sent a moment earlier with the
        # same key, so that key is looked up again.
        render(**(seen_request_key || { json: { message: 'Someone else was changing these meals at the same ' \
                                                         'time. Nothing was saved. Try again.' },
                                        status: :conflict }))
      end

      private

      # The 201 for a saved settlement, built from what it read inside its
      # own transaction. A Date is written in JSON as YYYY-MM-DD.
      sig { params(settlement: Settlement).returns(T::Hash[Symbol, T.untyped]) }
      def created(settlement)
        reconciliation = settlement.reconciliation
        { json: { id: reconciliation.id, date: reconciliation.date, cutoff_date: reconciliation.end_date,
                  meal_count: settlement.meal_count },
          status: :created }
      end

      # The caller sends `cutoff`; the row stores it as end_date, and the
      # row's own full message would say "End date", a name the caller never
      # sent. So an end_date refusal is named `cutoff`, which gives the same
      # words preview answers for the same cutoff (Settlement.preview).
      sig { params(errors: ActiveModel::Errors).returns(String) }
      def in_the_callers_words(errors)
        errors.map { |error| error.attribute == :end_date ? "cutoff #{error.message}" : error.full_message }
              .to_sentence
      end

      # Settling is a money-path write with no undo, and the preview shows
      # every resident's balance. Both are for the person who does the
      # books: a superuser grants residents.can_reconcile in admin (#72).
      # A resident token never expires, so "any logged-in resident" would
      # mean anyone who picks up a signed-in phone. The Common House screen
      # is not a resident at all, so it gets the 403 of not_a_resident_api.
      sig { void }
      def require_reconciler
        resident = current_resident_api
        return not_a_resident_api if resident.nil?
        return if resident.can_reconcile?

        render json: { message: 'Only a resident with the reconciler role may do this. Ask an admin.' },
               status: :forbidden
      end
    end
  end
end
