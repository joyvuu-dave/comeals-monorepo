# frozen_string_literal: true

module Api
  module V1
    class MealsController < ApiController
      # Whole cents, 0 to 9999.99. The SPA blocks input that breaks this
      # grammar (app/frontend/src/helpers/money.ts holds the same pattern);
      # here it is enforced, never rounded. Bill's model validation and the
      # bills_amount_whole_cents CHECK constraint stand behind it.
      WHOLE_CENTS_AMOUNT = /\A\d{1,4}(\.\d{1,2})?\z/

      before_action :authenticate
      before_action :set_meal, except: [:next]
      before_action :reject_if_reconciled, only: %i[
        create_meal_resident destroy_meal_resident update_meal_resident
        create_guest destroy_guest
        update_description update_max update_bills update_closed
      ]
      before_action :verify_resident_exists, only: %i[create_meal_resident create_guest]
      before_action :set_guest, only: [:destroy_guest]
      before_action :set_meal_resident, only: %i[destroy_meal_resident update_meal_resident]
      after_action :trigger_pusher, except: %i[next history show_cooks]

      # GET /api/v1/meals/next
      def next
        next_meal = Meal.where(date: Time.zone.now.to_date..)
                        .order(:date).first

        if next_meal.nil?
          render json: { meal_id: nil }, status: :bad_request
        else
          render json: { meal_id: next_meal.id }
        end
      end

      # GET /api/v1/meals/:meal_id/history
      def history
        render json: {
          date: @meal.date,
          items: AuditSerializer.new(@meal.total_audits).to_h
        }
      end

      # POST /api/v1/meals/:meal_id/residents/:resident_id { late, vegetarian }
      # Uses pessimistic locking (SELECT ... FOR UPDATE) to prevent concurrent
      # signups from exceeding meal.max. The lock serializes writes to the same
      # meal row; other meals are unaffected.
      #
      # Uses find_or_initialize_by(resident_id:) rather than the previous
      # find_or_create_by(resident_id:, late:, vegetarian:). This means
      # re-signing up with different late/vegetarian values updates the
      # existing signup instead of erroring on the unique index.
      def create_meal_resident
        result = with_meal_lock do
          meal_resident = @meal.meal_residents.find_or_initialize_by(resident_id: params[:resident_id])
          meal_resident.assign_attributes(late: params[:late], vegetarian: params[:vegetarian])
          if meal_resident.save
            { json: MealResidentSerializer.new(meal_resident) }
          else
            { json: { message: meal_resident.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # DELETE /api/v1/meals/:meal_id/residents/:resident_id
      # The model guards (ClosedMealAttendanceFreeze, ReconciledMealImmutability)
      # are the source of truth; a blocked destroy surfaces here as a 400.
      def destroy_meal_resident
        result = with_meal_lock do
          if @meal_resident.destroy
            { json: { message: 'MealResident destroyed.' } }
          else
            { json: { message: @meal_resident.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # PATCH /api/v1/meals/:meal_id/residents/:resident_id { late, vegetarian }
      def update_meal_resident
        result = with_meal_lock do
          if @meal_resident.update(meal_resident_params)
            { json: { message: 'MealResident updated.' } }
          else
            { json: { message: @meal_resident.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # POST /api/v1/meals/:meal_id/residents/:resident_id/guests { vegetarian }
      # Uses pessimistic locking to prevent concurrent guest additions from
      # exceeding meal.max.
      def create_guest
        result = with_meal_lock do
          # multiplier omitted intentionally — DB default of 2 applies (adult guest).
          guest = Guest.new(meal_id: @meal.id, resident_id: params[:resident_id], vegetarian: params[:vegetarian])
          if guest.save
            { json: GuestSerializer.new(guest) }
          else
            { json: { message: guest.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id
      # The model guards (ClosedMealAttendanceFreeze, ReconciledMealImmutability)
      # are the source of truth; a blocked destroy surfaces here as a 400.
      def destroy_guest
        result = with_meal_lock do
          if @guest.destroy
            { json: { message: 'Guest was destroyed.' } }
          else
            { json: { message: @guest.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # GET /api/v1/meals/:meal_id/cooks
      def show_cooks
        key = "meal-#{params[:meal_id]}"

        cached_value = Rails.cache.read(key)

        if cached_value.nil?
          # @meal.meal_residents is already loaded by set_meal's .includes(),
          # so the serializer's attending lookup costs no query.
          result = MealFormSerializer.new(@meal).to_h
          Rails.cache.write(key, result)
        else
          result = cached_value
        end

        render json: result
      end

      # PATCH /api/v1/meals/:meal_id/description { description }
      def update_description
        result = with_meal_lock do
          if @meal.update(description: params[:description])
            { json: { message: 'Description updated.' } }
          else
            { json: { message: @meal.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # PATCH /api/v1/meals/:meal_id/max { max }
      # Locked so the max >= attendees_count validation reads the fresh
      # attendance, not the request-start snapshot.
      #
      # A cap on an open meal is an error, not a silent no-op. Without the
      # guard, conditionally_set_max nils the value inside before_save and
      # the client gets a 200 for a cap the server will never enforce.
      def update_max
        result = with_meal_lock do
          if !@meal.closed? && params[:max].present?
            { json: { message: 'Meal is open. A cap can only be set on a closed meal.' },
              status: :bad_request }
          elsif @meal.update(max: params[:max])
            { json: { message: 'Meal max value updated.' } }
          else
            { json: { message: @meal.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      # PATCH /meals/:meal_id/bills
      # PAYLOAD {id: 1, bills: [{resident_id: 3, amount: "0.00",
      #   no_cost: true}, {resident_id: "4", amount: "0.00",
      #   no_cost: true}]}
      def update_bills # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength --multi-step bill validation + cook-scheduling guards
        message = 'Form submitted.'
        request_symbol = :ok
        message_type = nil

        # Cooks
        cook_ids = params[:bills].pluck('resident_id') # rubocop:disable Rails/StrongParametersExpect --:bills is an array param; params.expect(:bills) raises ParameterMissing on arrays

        duplicate = cook_ids.map(&:to_i).tally.find { |_, count| count > 1 }&.first
        if duplicate
          render json: { message: "Duplicate cook in bills: resident ##{duplicate}." }, status: :bad_request
          return
        end

        warning = ThirdCookWarning.for(@meal, cook_ids)
        if warning
          message = warning
          request_symbol = :bad_request
          message_type = 'warning'
        end

        # Validate all amounts before any DB writes. A row without value
        # keys names a cook the user did not touch: it keeps the bill alive
        # (a cook left out of the payload is removed below) but its stored
        # amount and no_cost are never rewritten.
        parsed_bills = []
        params[:bills].each do |bill|
          unless bill.key?('amount') || bill.key?('no_cost')
            parsed_bills << { resident_id: bill['resident_id'], touched: false }
            next
          end
          amount_str = bill['amount'].to_s
          amount_str = '0' if amount_str.blank?
          unless WHOLE_CENTS_AMOUNT.match?(amount_str)
            render json: { message: "Invalid amount: #{bill['amount']}. Amounts are whole cents, 0 to 9999.99." },
                   status: :bad_request
            return # rubocop:disable Lint/NonLocalExitFromIterator -- intentional: render error and exit action
          end
          parsed_bills << {
            resident_id: bill['resident_id'], amount: BigDecimal(amount_str), no_cost: bill['no_cost'],
            touched: true
          }
        end

        # Verify all cooks are valid residents
        valid_ids = Resident.where(id: cook_ids).pluck(:id)
        invalid_ids = cook_ids.map(&:to_i) - valid_ids
        if invalid_ids.any?
          render json: { message: 'Resident not found.' }, status: :bad_request
          return
        end

        # Pessimistic lock on the meal row prevents concurrent update_bills
        # calls from interleaving (same pattern as create_meal_resident), and
        # with_meal_lock's reconciled? re-check rejects a sweep that committed
        # after the reject_if_reconciled check above. Bills are diffed and
        # destroyed explicitly — never through cook_ids=, which would swallow
        # a guard-blocked removal silently. destroy! runs the audited hooks
        # and the reconciled guard as a second line of defense.
        rejection = with_meal_lock do
          @meal.bills.where.not(resident_id: cook_ids).find_each(&:destroy!)
          parsed_bills.each do |bill|
            record = @meal.bills.find_or_initialize_by(resident_id: bill[:resident_id])
            if bill[:touched]
              record.update!(amount: bill[:amount], no_cost: bill[:no_cost])
            elsif record.new_record?
              # An untouched row for a cook with no bill yet: create it with
              # the column defaults (amount 0, no_cost false).
              record.save!
            end
          end
          nil
        end
        # with_meal_lock returns the rejection if the sweep won.
        return render(**rejection) if rejection

        payload = { message: message }
        payload[:type] = message_type if message_type
        # The rows as stored (same shape as the meal form's bills), so the
        # client can display what the server persisted instead of trusting
        # what it sent. reload defeats the association cache — the rows were
        # rewritten under the lock above.
        payload[:bills] = @meal.bills.reload.map { |bill| bill.slice(:resident_id, :amount, :no_cost) }
        render json: payload, status: request_symbol
      rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
        @skip_pusher = true
        render json: { message: e.message }, status: :bad_request
      rescue ActiveRecord::RecordNotDestroyed => e
        @skip_pusher = true
        render json: { message: e.record.errors.full_messages.join("\n") }, status: :bad_request
      rescue ActiveRecord::InvalidForeignKey
        @skip_pusher = true
        render json: { message: 'Invalid cook assignment.' }, status: :bad_request
      rescue ActiveRecord::RangeError
        # Unreachable while the grammar check above holds (it caps amounts at
        # 9999.99, which fits DECIMAL(12,8)) — kept so a value that would
        # overflow the column can never surface as a 500.
        @skip_pusher = true
        render json: { message: 'Invalid amount. Amounts are whole cents, 0 to 9999.99.' }, status: :bad_request
      end

      # PATCH /api/v1/meals/:meal_id/closed { closed }
      def update_closed
        result = with_meal_lock do
          if @meal.update(closed: params[:closed])
            { json: { message: 'Meal closed value updated.' } }
          else
            { json: { message: @meal.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
        render(**result)
      end

      private

      def meal_resident_params
        params.permit(:late, :vegetarian)
      end

      def reject_if_reconciled
        return unless @meal.reconciled?

        render(**reconciled_rejection)
      end

      # The render arguments, not the render. with_meal_lock returns this from
      # inside the transaction and the action renders it afterwards.
      def reconciled_rejection
        @skip_pusher = true
        { json: { message: 'Change not permitted. Meal has already been reconciled.' },
          status: :bad_request }
      end

      # Serializes the write against Settlement#assign_meals' update_all
      # (row locks on the swept meals) and re-checks reconciled? on the lock's
      # fresh reload. The reject_if_reconciled before_action reads the meal
      # before the lock is taken, so a settlement committing mid-request slips
      # past it — the rake task runs in its own dyno, and the Puma thread count
      # is irrelevant to that. with_lock reloads @meal, so records pinned to it
      # via inverse_of run their model guards against the fresh state too.
      #
      # This lock is what makes the API path correct, and it works in both
      # orders: with_lock takes FOR UPDATE, assign_meals' update_all takes
      # FOR NO KEY UPDATE, and those two conflict. Whichever transaction is
      # second waits and then sees the other's committed result.
      #
      # Every money-mutating path should go through here, because it is the
      # only one that fails politely. Paths that skip it (ActiveAdmin's bill
      # and attendance forms) are not unprotected — the immutability triggers
      # take locking reads, so a racing write waits for the settlement and is
      # then refused — but they are refused by a database exception, not a
      # 400 with a readable message. See
      # docs/adr/0003-concurrency-on-the-money-path.md.
      #
      # Nothing here renders. The block returns the render arguments and the
      # action renders them after the transaction commits. A render inside the
      # transaction would raise DoubleRenderError the moment the block is run a
      # second time, which is what a retry on a serialization failure does. See
      # docs/adr/0005-serializable-by-default.md.
      #
      # RetryOnConflict goes outside with_lock, not inside. It refuses to
      # retry when a transaction is already open, because every statement in
      # a refused transaction fails too. Inside the lock it would do nothing.
      #
      # At SERIALIZABLE, PostgreSQL can refuse this transaction even though
      # the lock was granted: the lock orders two writers on the same meal,
      # and SSI can still find a cycle through rows the lock does not cover.
      # Three attempts, then a 409. Nothing is written when it gives up, so
      # the message can tell the user that plainly.
      def with_meal_lock
        RetryOnConflict.call do
          @meal.with_lock do
            if @meal.reconciled?
              reconciled_rejection
            else
              yield
            end
          end
        end
      rescue ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
        # LockWaitTimeout is here too: lock_timeout (config/database.yml)
        # refused the wait for the meal row after 5 seconds — another
        # writer, usually a running settlement, still holds it. Same story
        # as a conflict, same answer: nothing was saved, try again. Not
        # retried by RetryOnConflict: a lock held for 5 seconds is likely
        # still held, and the retry delays are milliseconds.
        conflict_rejection
      end

      # The render arguments, not the render — same as reconciled_rejection.
      # 409 Conflict, because the request was fine and would work if sent
      # again. Nothing was written, so there is no Pusher event to send.
      def conflict_rejection
        @skip_pusher = true
        { json: { message: 'Someone else was changing this meal at the same time. ' \
                           'Nothing was saved. Try again.' },
          status: :conflict }
      end

      def verify_resident_exists
        return if Resident.exists?(id: params[:resident_id])

        render json: { message: 'Resident not found.' }, status: :bad_request
      end

      def set_meal
        @meal = Meal.includes(:bills, :meal_residents, :guests).find_by(id: params[:meal_id]) unless defined?(@meal)

        return not_found_api if @meal.blank?

        @meal.socket_id = params[:socket_id]
      end

      def set_guest
        @guest = @meal.guests.find_by(id: params[:guest_id])

        not_found_api if @guest.blank?
      end

      def set_meal_resident
        unless defined?(@meal_resident)
          @meal_resident = MealResident.find_by(meal_id: params[:meal_id], resident_id: params[:resident_id])
        end

        not_found_api if @meal_resident.blank?
      end

      def trigger_pusher
        return if @skip_pusher

        @meal.trigger_pusher
      end
    end
  end
end
