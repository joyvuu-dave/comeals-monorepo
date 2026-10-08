# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class MealsController < ApiController
      extend T::Sig

      # What an action hands to render: { json:, status: }.
      Rendering = T.type_alias { T::Hash[Symbol, T.untyped] }

      # The two answers to a bills save whose Idempotency-Key this meal
      # has seen (answer_seen_key).
      REPLAYED = T.let('This save was already made, so nothing more was written.', String)
      KEY_REUSED = T.let('This Idempotency-Key was already used for a different save. Nothing was saved. ' \
                         'Send a new key with each save.', String)
      private_constant :REPLAYED, :KEY_REUSED

      before_action :authenticate
      before_action :set_meal, except: [:next]
      # Before the settled check, so a bills save sent again after its
      # first try was written is not told that nothing was saved.
      before_action :answer_seen_bills_key, only: [:update_bills]
      before_action :reject_if_reconciled, only: %i[
        create_meal_resident destroy_meal_resident update_meal_resident
        create_guest destroy_guest
        update_description update_max update_bills update_closed
      ]
      before_action :verify_resident_exists, only: %i[create_meal_resident create_guest]
      before_action :set_guest, only: [:destroy_guest]
      before_action :set_meal_resident, only: %i[destroy_meal_resident update_meal_resident]

      # GET /api/v1/meals/next
      sig { void }
      def next
        next_meal = Meal.where(date: Community.instance.today..)
                        .order(:date).first

        if next_meal.nil?
          render json: { meal_id: nil }, status: :bad_request
        else
          render json: { meal_id: next_meal.id }
        end
      end

      # GET /api/v1/meals/:meal_id/history
      sig { void }
      def history
        render json: {
          date: meal.date,
          items: AuditSerializer.new(meal.total_audits).to_h
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
      #
      # Both flags are required, on a re-signup too (#121), and each must
      # be a value TrueOrFalse takes (#138). Otherwise the answer is a 400,
      # and the stored row is unchanged.
      sig { void }
      def create_meal_resident
        flags = TrueOrFalse.from_params(params, %i[late vegetarian], required: true)
        return render_refused(flags) if flags.is_a?(String)

        render_write_under_lock do
          meal_resident = meal.meal_residents.find_or_initialize_by(resident_id: params[:resident_id])
          meal_resident.update!(flags)
          { json: MealResidentSerializer.new(meal_resident) }
        end
      end

      # DELETE /api/v1/meals/:meal_id/residents/:resident_id
      # The model guards (ClosedMealAttendanceFreeze, ReconciledMealImmutability)
      # are the source of truth; a blocked destroy surfaces here as a 400.
      sig { void }
      def destroy_meal_resident
        render_write_under_lock do
          meal_resident.destroy!
          { json: { message: 'MealResident destroyed.' } }
        end
      end

      # PATCH /api/v1/meals/:meal_id/residents/:resident_id { late, vegetarian }
      # A flag left out keeps its stored value (the SPA sends one at a
      # time). A flag sent must be a value TrueOrFalse takes (#121, #138).
      sig { void }
      def update_meal_resident
        flags = TrueOrFalse.from_params(params, %i[late vegetarian], required: false)
        return render_refused(flags) if flags.is_a?(String)

        render_write_under_lock do
          meal_resident.update!(flags)
          { json: { message: 'MealResident updated.' } }
        end
      end

      # POST /api/v1/meals/:meal_id/residents/:resident_id/guests { vegetarian }
      # Uses pessimistic locking to prevent concurrent guest additions from
      # exceeding meal.max. vegetarian is required (#121), and must be a
      # value TrueOrFalse takes (#138); otherwise the answer is a 400.
      sig { void }
      def create_guest
        flags = TrueOrFalse.from_params(params, %i[vegetarian], required: true)
        return render_refused(flags) if flags.is_a?(String)

        render_write_under_lock do
          # multiplier omitted intentionally — DB default of 2 applies (adult guest).
          guest = Guest.new(meal_id: meal.id, resident_id: params[:resident_id], vegetarian: flags.fetch(:vegetarian))
          guest.save!
          { json: GuestSerializer.new(guest) }
        end
      end

      # DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id
      # The model guards (ClosedMealAttendanceFreeze, ReconciledMealImmutability)
      # are the source of truth; a blocked destroy surfaces here as a 400.
      sig { void }
      def destroy_guest
        render_write_under_lock do
          guest.destroy!
          { json: { message: 'Guest was destroyed.' } }
        end
      end

      # GET /api/v1/meals/:meal_id/cooks
      #
      # Built fresh on every request, on purpose. This page used to be
      # cached under meal-<id>, and the cache was cleared only when the
      # meal itself was written or settled. But the page also holds the
      # residents list (the name, unit and active flag of each resident it
      # shows, for the sign-up list and the cook menus) and the
      # ids of the meals before and after this one, and nothing cleared
      # the entry when a resident was retired or renamed or when the next
      # rotation was created — so the page showed old data for up to a
      # day (#76). The cache also saved almost nothing: set_meal already
      # loads the meal, its bills, attendance and guests, and the rest is
      # three small queries. spec/requests/api/v1/meal_cooks_performance_spec.rb
      # bounds them.
      sig { void }
      def show_cooks
        render json: MealFormSerializer.new(meal)
      end

      # PATCH /api/v1/meals/:meal_id/description { description }
      sig { void }
      def update_description
        render_write_under_lock do
          meal.update!(description: params[:description])
          { json: { message: 'Description updated.' } }
        end
      end

      # PATCH /api/v1/meals/:meal_id/max { max }
      # Locked so the max >= attendees_count validation reads the fresh
      # attendance, not the request-start snapshot.
      #
      # A cap on an open meal is an error, not a silent no-op. Without the
      # guard, conditionally_set_max nils the value inside before_save and
      # the client gets a 200 for a cap the server will never enforce.
      sig { void }
      def update_max
        render_write_under_lock do
          if !meal.closed? && params[:max].present?
            { json: { message: 'Meal is open. A cap can only be set on a closed meal.' },
              status: :bad_request }
          else
            meal.update!(max: params[:max])
            { json: { message: 'Meal max value updated.' } }
          end
        end
      end

      # PATCH /api/v1/meals/:meal_id/bills
      # Idempotency-Key: "8e03978e-40d5-43e8-bc93-6894a57f9324"
      # { edits: [{ op: "change", resident_id: 9,
      #             from: { amount: "5.0", no_cost: false },
      #             to: { amount: "7.00", no_cost: false } }, ...] }
      #
      # Each edit names one cook and the bill the page saw for that cook,
      # and BillsPayload checks and writes them (#135, ADR 0009). This
      # action does the request's part. The checks, in order:
      #
      #   1. A key this meal has a row for, with a body and key that are
      #      right, gets the answer for a seen key (answer_seen_bills_key).
      #   2. A settled meal gets the settled words (reject_if_reconciled).
      #   3. A body in the old format, which listed every cook, is refused
      #      as out of date. A page that old sends no key either, and "out
      #      of date" is what tells the person what to do.
      #   4. A missing or wrong Idempotency-Key header (IdempotencyKeyHeader).
      #   5. Wrong edits.
      #
      # These run before the lock and write nothing, so a problem in any of
      # them means no edit is written. The rest runs under the meal lock
      # (with_meal_lock), which looks up the key and then checks reconciled?
      # again on the fresh row, so a save that committed, or a settlement
      # that committed, after the checks above is seen. See save_bills.
      sig { void }
      def update_bills
        payload = bills_payload
        return refuse_outdated_bills(payload) if payload.outdated?

        header = bills_key_header
        key = header.key
        return render json: { message: header.error }, status: :bad_request if key.nil?
        return render json: { message: payload.error }, status: :bad_request unless payload.valid?

        render(**T.must(with_meal_lock(before_settled_check: -> { seen_bills_key_answer }) do
          save_bills(payload, key)
        end))
      rescue ActiveRecord::RecordNotFound => e
        render json: { message: e.message }, status: :bad_request
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
        # The record's own sentences, the same as render_write_under_lock,
        # not RecordInvalid's "Validation failed: ..." text.
        render json: { message: e.record.errors.full_messages.join("\n") }, status: :bad_request
      rescue ActiveRecord::InvalidForeignKey
        render json: { message: 'Invalid cook assignment.' }, status: :bad_request
      rescue ActiveRecord::RangeError
        # Unreachable while BillsPayload's grammar holds (it caps amounts at
        # 9999.99, which fits DECIMAL(12,8)) — kept so a value that would
        # overflow the column can never surface as a 500.
        render json: { message: 'Invalid amount. Amounts are whole cents, 0 to 9999.99.' }, status: :bad_request
      end

      # PATCH /api/v1/meals/:meal_id/closed { closed }
      # closed is required, and must be a value TrueOrFalse takes. Before
      # #138 "no" closed the meal, and before #139 a missing closed was a
      # 500.
      sig { void }
      def update_closed
        flags = TrueOrFalse.from_params(params, %i[closed], required: true)
        return render_refused(flags) if flags.is_a?(String)

        render_write_under_lock do
          meal.update!(closed: flags.fetch(:closed))
          { json: { message: 'Meal closed value updated.' } }
        end
      end

      private

      # One write under the meal lock, rendered. The block writes with the
      # bang methods (save!, update!, destroy!) and returns what to render
      # on success; a refusal by a model guard or a validation raises,
      # unwinds the transaction, and is rendered here as a 400 with the
      # record's own sentences. Every single-record write action goes
      # through here, so a new one cannot skip the lock (CLAUDE.md, money
      # rule 9) or answer a refusal with a 500.
      sig { params(blk: T.proc.returns(Rendering)).void }
      # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding -- the sig above has to name the block
      def render_write_under_lock(&blk)
        render(**T.must(with_meal_lock(&blk)))
        # rubocop:enable Naming/BlockForwarding, Style/ArgumentsForwarding
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
        render json: { message: e.record.errors.full_messages.join("\n") }, status: :bad_request
      end

      # A bills save under the meal lock, once per try: RetryOnConflict
      # runs it again after a conflict, so every read here is fresh on
      # each try. Before it, in the same try, with_meal_lock has looked up
      # the key (seen_bills_key_answer) and checked that the meal is not
      # settled.
      #
      # The stored bills are read once. If any edit was built on a bill
      # that has changed since the page read it, nothing is written, and
      # the answer is a 409 of type 'stale' that carries the bills as
      # stored. Otherwise the edits are written, and so is the key's row,
      # in the same transaction: a try that is rolled back takes its key
      # with it, so the next try is not answered as already made. The
      # third-cook warning and the answer's bills are read after the
      # writes, in the same transaction, so both describe what this save
      # left.
      #
      # The meal lock runs two saves with the same key one after the other.
      # The second still reads the table as it was before the first
      # committed, because its snapshot is taken by the lock it waited
      # for. PostgreSQL refuses it as a conflict, even when the refusal
      # comes at its insert of the same key, and the next try finds the
      # key (spec/requests/api/v1/bills_idempotency_key_race_spec.rb). So
      # a RecordNotUnique here would mean the look-up was skipped.
      sig { params(payload: BillsPayload, key: String).returns(Rendering) }
      def save_bills(payload, key)
        stored = T.let(meal.bills.reload.index_by(&:resident_id), T::Hash[Integer, Bill])
        stale = payload.write_to(meal, stored)
        return { json: { message: stale, type: 'stale', bills: bill_rows(stored.values) }, status: :conflict } if stale

        BillsSaveKey.create!(meal: meal, key: key, edits_sha256: payload.fingerprint)
        warning = ThirdCookWarning.for(meal, stored.keys)
        bills_written(warning)
      end

      # Runs before reject_if_reconciled, for update_bills only. A key this
      # meal has a row for belongs to a save that was written, while the
      # meal was open, so its answer comes before the settled check: the
      # settled words would say that nothing was saved, which is false.
      sig { void }
      def answer_seen_bills_key
        answer = seen_bills_key_answer
        render(**answer) if answer
      end

      # The answer to a bills save whose key this meal has a row for
      # (answer_seen_key), or nil. A save whose body or key is wrong is not
      # looked up, so it gets the other checks, in their usual order.
      # update_bills runs this before the lock (answer_seen_bills_key) and
      # again under it, in each try, before the settled check: a first try
      # that commits while this save waits for the lock is found there.
      sig { returns(T.nilable(Rendering)) }
      def seen_bills_key_answer
        key = bills_key_header.key
        return nil if key.nil? || !bills_payload.valid?

        seen = BillsSaveKey.find_by(meal_id: meal.id, key: key)
        answer_seen_key(seen, bills_payload) if seen
      end

      # The bills save's body and Idempotency-Key header, each read once
      # per request: answer_seen_bills_key reads them before update_bills
      # does.
      sig { returns(BillsPayload) }
      def bills_payload
        @bills_payload ||= T.let(BillsPayload.parse(params), T.nilable(BillsPayload))
      end

      sig { returns(IdempotencyKeyHeader) }
      def bills_key_header
        @bills_key_header ||= T.let(IdempotencyKeyHeader.new(request.headers['Idempotency-Key']),
                                    T.nilable(IdempotencyKeyHeader))
      end

      # The answer to a save whose key was already used on this meal. With
      # the same edits it is the same save sent again, whose first try was
      # written: a 200 of type 'replayed' with the bills as stored now,
      # which may differ from what that try wrote if someone saved since.
      # With other edits it is a mistake in the client, and the IETF draft
      # answers it with 422.
      sig { params(seen: BillsSaveKey, payload: BillsPayload).returns(Rendering) }
      def answer_seen_key(seen, payload)
        if seen.edits_sha256 == payload.fingerprint
          { json: { message: REPLAYED, type: 'replayed', bills: bill_rows(meal.bills.reload) }, status: :ok }
        else
          { json: { message: KEY_REUSED }, status: :unprocessable_content }
        end
      end

      # The answer to a bills write: the message, the warning's type when
      # there is one, and the rows as stored (same shape as the meal
      # form's bills). The warning is a 400 with type 'warning', but the
      # write happened: the warning is advice about the rotation, not a
      # refusal. reload reads the rows again, because the meal's loaded
      # list still holds any bill this save destroyed.
      sig { params(warning: T.nilable(String)).returns(Rendering) }
      def bills_written(warning)
        body = { message: warning || 'Form submitted.' }
        body[:type] = 'warning' if warning
        body[:bills] = bill_rows(meal.bills.reload)
        { json: body, status: warning ? :bad_request : :ok }
      end

      sig { params(bills: T::Enumerable[Bill]).returns(T::Array[T::Hash[String, T.untyped]]) }
      def bill_rows(bills)
        bills.map { |bill| bill.slice(:resident_id, :amount, :no_cost) }
      end

      # A page loaded before #135 still sends every cook it shows, and the
      # server used to remove any cook the list left out. That is how a
      # page that had not yet seen another page's save deleted a cook. The
      # one line in the log shows how often old pages still try.
      sig { params(payload: BillsPayload).void }
      def refuse_outdated_bills(payload)
        Rails.logger.info("Refused a bills save in the old format for meal #{meal.id}: " \
                          'the page was loaded before #135.')
        render json: { message: payload.error, type: 'outdated' }, status: :bad_request
      end

      sig { void }
      def reject_if_reconciled
        return unless meal.reconciled?

        render(**reconciled_rejection)
      end

      # The render arguments, not the render. with_meal_lock returns this from
      # inside the transaction and the action renders it afterwards.
      sig { returns(Rendering) }
      def reconciled_rejection
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
      # one that retries and answers 400 with a readable message. Paths that
      # skip it (ActiveAdmin's bill and attendance forms) are not
      # unprotected: the model takes the meal lock (LocksItsMealFirst), the
      # reconciled guard reads the meals table, and the immutability
      # triggers take locking reads, so a racing write waits for the
      # settlement and is then refused with the guard's sentence or the
      # admin conflict alert. See
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
      # before_settled_check runs under the lock, before reconciled?, in
      # each try. When it returns an answer, that is the answer, and the
      # block does not run. Only a bills save passes one: a save whose
      # first try was written is answered as already made, even when the
      # meal was settled after that try (seen_bills_key_answer).
      #
      # At SERIALIZABLE, PostgreSQL can refuse this transaction even though
      # the lock was granted: the lock orders two writers on the same meal,
      # and SSI can still find a cycle through rows the lock does not cover.
      # Three attempts, then a 409. Nothing is written when it gives up, so
      # the message can tell the user that plainly.
      #
      # A refused attempt leaves the values it tried to write on the record
      # in memory: Rails rolls the row back, not the assignment, and
      # `with_lock` refuses to lock a record with unsaved changes. So each
      # attempt first drops them; the lock's reload reads the row fresh.
      # Without this the retry was a 500 (spec/requests/api/v1/meal_write_retry_spec.rb).
      sig do
        params(before_settled_check: T.nilable(T.proc.returns(T.nilable(Rendering))),
               blk: T.proc.returns(T.nilable(Rendering))).returns(T.nilable(Rendering))
      end
      def with_meal_lock(before_settled_check: nil, &blk)
        RetryOnConflict.call do
          meal.restore_attributes
          meal.with_lock do
            answer = before_settled_check&.call
            if answer
              answer
            elsif meal.reconciled?
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
      # again. Nothing was written, so nothing is pushed: the models push,
      # and a rolled-back write drops its pushes with it (LiveUpdate).
      sig { returns(Rendering) }
      def conflict_rejection
        { json: { message: 'Someone else was changing this meal at the same time. ' \
                           'Nothing was saved. Try again.' },
          status: :conflict }
      end

      sig { void }
      def verify_resident_exists
        return if Resident.exists?(id: params[:resident_id])

        render json: { message: 'Resident not found.' }, status: :bad_request
      end

      sig { void }
      def set_meal
        @meal = T.let(Meal.includes(:bills, :meal_residents, :guests).find_by(id: params[:meal_id]),
                      T.nilable(Meal))

        return not_found_api if @meal.nil?

        # The sender's Pusher socket. The models push (LiveUpdate); this
        # is how the meal-page push skips the browser that made the
        # change, which updated its own screen already.
        Current.socket_id = params[:socket_id].presence
      end

      sig { void }
      def set_guest
        @guest = T.let(meal.guests.find_by(id: params[:guest_id]), T.nilable(Guest))

        not_found_api if @guest.nil?
      end

      sig { void }
      def set_meal_resident
        @meal_resident = T.let(MealResident.find_by(meal_id: params[:meal_id], resident_id: params[:resident_id]),
                               T.nilable(MealResident))

        not_found_api if @meal_resident.nil?
      end

      # The records the before_actions loaded. Each before_action rendered
      # 404 and halted the chain when its record was missing, so by the time
      # an action runs these are never nil.
      sig { returns(Meal) }
      def meal = T.must(@meal)

      sig { returns(Guest) }
      def guest = T.must(@guest)

      sig { returns(MealResident) }
      def meal_resident = T.must(@meal_resident)
    end
  end
end
