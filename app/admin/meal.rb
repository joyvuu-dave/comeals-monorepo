# typed: false
# frozen_string_literal: true

ActiveAdmin.register Meal do
  # STRONG PARAMS
  # attendee_ids is deliberately absent: ids-assignment on the through
  # association removes MealResident rows without their audit hooks or
  # closed/reconciled guards running per row (issue #7). Attendance is
  # managed through the API, which operates on individual rows.
  # guests_attributes has no meal_id: a nested guest belongs to the form's
  # meal by construction, and permitting the key let a hand-made request
  # move an existing guest to another meal past the closed-meal freeze
  # (lock hunt, 2026-09-21; the freeze refuses a move now too).
  # rotation_id only on create (#100): every meal belongs to a rotation,
  # and the New Meal form asks which one. A meal keeps the rotation it
  # was made in, so the edit form has no menu and an update ignores the
  # key.
  permit_params do
    permitted = [:date, :closed, :max, { guests_attributes: %i[id multiplier resident_id _destroy] }]
    permitted.unshift(:rotation_id) if params[:action] == 'create'
    permitted
  end

  # The New Meal form and the edit form refuse a date after the last meal
  # of the calendar (#143, Meal#date_not_after_the_last_rotation).
  # ActiveAdmin runs this block just before it saves, on create and on
  # update.
  before_save { |meal| meal.from_admin_form = true }

  # CONFIG
  # include_blank adds "Any", which is what the list shows before a filter
  # is applied: open and reconciled meals together.
  filter :reconciliation_id_null, as: :select, collection: [['Yes', false], ['No', true]], include_blank: true,
                                  label: 'Reconciled?'
  config.sort_order = 'date_desc'

  # ADR 0011 rule 6: a settled dinner is changed by a correction, which
  # the next settlement carries. The GET shows the form. The Preview
  # button shows what the correction would do (MealCorrecting.preview,
  # which saves nothing). The Save button sends the preview's
  # fingerprint, and saves only that: if the dinner or the form changed
  # after the preview, it saves nothing and shows the new preview
  # (app/views/admin/meals/correct.html.arb, MealCorrectionForm). A
  # correction writes the ledger, so it needs a superuser.
  member_action :correct, method: %i[get post] do
    # Hand-written action: ActiveAdmin authorizes :read inside resource,
    # and nothing else (the meal_resident.rb trap, ADR 0004).
    authorize! :create, MealCorrection
    unless resource.reconciled?
      return redirect_to(admin_meal_path(resource),
                         alert: 'This dinner is not settled yet, so it is changed directly, not corrected.')
    end
    if resource.cancelled?
      return redirect_to(admin_meal_path(resource),
                         alert: 'This dinner was cancelled, so it charged nobody and has nothing to correct.')
    end

    @page_title = "Correct the #{resource.date.iso8601} Dinner"
    @values = correction_values
    correct_from_form if request.post?
  end

  action_item :correct, only: :show, if: lambda {
    resource.reconciled? && !resource.cancelled? && authorized?(:create, MealCorrection)
  } do
    link_to 'Correct this dinner', correct_admin_meal_path(resource)
  end

  # Cancel a dinner, or restore one (ADR 0011 rule 11). Any admin may,
  # because neither moves money: a dinner a cook spent money on cannot be
  # cancelled, and a cancelled one charges nobody (SuperuserAdapter,
  # DINNER_ACTIONS). Each button asks first, and the meal page has the
  # same two.
  member_action :cancel, method: :post do
    authorize! :cancel, resource
    change_cancelled(cancel: true)
  end

  member_action :restore, method: :post do
    authorize! :restore, resource
    change_cancelled(cancel: false)
  end

  action_item :cancel, only: :show, if: lambda {
    !resource.reconciled? && !resource.cancelled? && authorized?(:cancel, resource)
  } do
    link_to 'Cancel', cancel_admin_meal_path(resource), method: :post, data: { confirm: 'Cancel this dinner?' }
  end

  action_item :restore, only: :show, if: lambda {
    !resource.reconciled? && resource.cancelled? && authorized?(:restore, resource)
  } do
    link_to 'Restore', restore_admin_meal_path(resource), method: :post, data: { confirm: 'Restore this dinner?' }
  end

  controller do
    include RefusedDestroyMessage

    # Reconciled meals are immutable — block edit/update/destroy. A guest
    # added through the nested form would otherwise be refused by the guest's
    # own validation, with its sentence copied onto the meal's errors; the
    # redirect is the clearer screen.
    before_action :block_if_reconciled, only: %i[edit update destroy]

    def scoped_collection
      # Everything MealCostSummary reads, so the index computes each
      # row's numbers without per-row queries.
      end_of_association_chain.includes(:bills, :meal_residents, :guests, :meal_charges)
    end

    def block_if_reconciled
      return unless resource.reconciled?

      redirect_to admin_meal_path(resource),
                  alert: 'This meal is reconciled and cannot be modified.'
    end

    # A nested guest refused by the closed-meal freeze (ClosedMealAttendanceFreeze)
    # fails in two different ways. An add is a validation error on the
    # guest, which Rails copies onto meal.errors[:guests] and the form shows
    # (see semantic_errors below). A remove is a before_destroy abort, which
    # Rails raises as RecordNotDestroyed out of the nested save. Catch it
    # and show the same sentence, instead of a 500 page.
    def update
      update!
    rescue ActiveRecord::RecordNotDestroyed => e
      resource.errors.add(:guests, e.record.errors.full_messages.to_sentence)
      render :edit
    end

    private

    # Under the meal's row lock, like every write to a meal's rows
    # (LocksItsMealFirst): a cost saved at the same moment either commits
    # first, and the cancel sees its money, or waits and is then refused.
    # with_lock reads the meal again, so a dinner settled or cancelled
    # since the page was drawn answers with its own sentence.
    def change_cancelled(cancel:)
      resource.with_lock { cancel ? resource.cancel! : resource.restore! }
      redirect_to admin_meal_path(resource), notice: cancel ? 'Dinner cancelled.' : 'Dinner restored.'
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      redirect_to admin_meal_path(resource), alert: e.record.errors.full_messages.to_sentence
    end

    # What the correction form sent, as plain data: each row by its id.
    def correction_values
      params.fetch(:correction, {})
            .permit(:reason, new_eater_ids: [], cooks: {}, eaters: {}, guests: {},
                             new_cook: %i[resident_id amount no_cost], new_guest: %i[host_id multiplier])
            .to_h
    end

    # The Preview button, or the Save button with the preview's
    # fingerprint. A Save with no fingerprint did not come from a
    # preview, so it shows one.
    def correct_from_form
      form = MealCorrectionForm.new(resource, @values)
      if params[:save].present? && params[:fingerprint].present?
        save_correction(form)
      else
        preview_correction(form)
      end
    rescue MealCorrectionForm::Invalid, MealCorrecting::NothingChanged, MealCorrecting::EarlierDifference => e
      flash.now[:alert] = e.message
    rescue ActiveRecord::RecordNotFound
      # Another correction took a row off between this form's read and
      # its edit of that row (MealCorrecting::Edits finds each row again).
      flash.now[:alert] = MealCorrectionForm::CHANGED
    end

    def preview_correction(form)
      @preview = MealCorrecting.preview(resource) { |edits| form.apply(edits) }
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
    end

    # A refused save shows why, and the preview again, so the Save button
    # is still there once the admin has fixed what was wrong.
    def save_correction(form)
      MealCorrecting.save!(resource, by: current_admin_user_custom, reason: form.reason,
                                     fingerprint: params[:fingerprint].to_s) { |edits| form.apply(edits) }
      redirect_to admin_meal_path(resource), notice: 'The correction is saved. The next settlement carries it.'
    rescue MealCorrecting::Changed
      preview_correction(form)
      flash.now[:alert] = 'The dinner or the form changed after the preview, so nothing was saved. This is the ' \
                          'preview as it is now. Look it over, then click Save correction again.'
    rescue ActiveRecord::RecordInvalid => e
      preview_correction(form)
      flash.now[:alert] = e.record.errors.full_messages.to_sentence
    end

    # Back to the meal, not the list: a closed meal is reopened from its
    # own page, and that is the next step after "reopen it before
    # deleting". Reconciled meals never reach this — block_if_reconciled
    # redirects first.
    def refused_destroy_path
      admin_meal_path(resource)
    end
  end

  # INDEX
  index do
    column :id
    column :date, sortable: :date do |meal|
      l(meal.date, format: :admin)
    end
    column :attendees_count, sortable: false
    column :closed
    column :max
    # Costs come from MealCostSummary: stored charges for settled meals,
    # MealLedger for open ones. Blank for a meal settled before line
    # items existed. (The old max_cost column is gone with the derived
    # methods — it applied today's cap to yesterday's meals.)
    column :subsidized? do |meal|
      MealCostSummary.for(meal)&.subsidized
    end
    column :total_cost do |meal|
      meal_cost_cell(meal, :total_cost)
    end
    column :unit_cost do |meal|
      meal_cost_cell(meal, :unit_cost)
    end
    column 'Number of Bills', :bills_count
    column :cancelled?, sortable: false
    column :reconciled?, sortable: false

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :date
      row('Cancelled') { meal.cancelled_at.strftime('%b %-d, %Y %-l:%M %p') } if meal.cancelled?
      row :closed
      row :max
      row :subsidized? do |meal|
        MealCostSummary.for(meal)&.subsidized
      end
      # From the rows as they are now: a corrected settled meal shows what
      # it costs after the correction (MealCostSummary.now).
      row :total_cost do |meal|
        meal_cost_cell(meal, :total_cost, now: true)
      end
      row :unit_cost do |meal|
        meal_cost_cell(meal, :unit_cost, now: true)
      end
      table_for meal.guests.order(:created_at) do
        column 'Guests in Attendance' do |guest|
          "Guest of #{guest.resident.name}"
        end
      end
      table_for meal.bills.all do
        column 'Bills' do |bill|
          link_to "#{bill.resident.name} - #{number_to_currency(bill.amount)}", admin_bill_path(bill)
        end
      end
    end

    # Attendance corrections (issue #25): one row per change, per-row
    # buttons — never a bulk grid. Controls disappear once the meal is
    # reconciled; the model guards refuse regardless. Lives outside the
    # attributes_table because forms may not nest inside a table body.
    panel 'Residents Attendance' do
      table_for(meal.meal_residents.includes(:resident).sort_by { |mr| mr.resident.name }) do
        column 'Resident' do |mr|
          link_to mr.resident.name, admin_resident_path(mr.resident)
        end
        unless meal.reconciled?
          column '' do |mr|
            button_to 'Remove', admin_meal_meal_resident_path(meal, mr),
                      method: :delete,
                      form: { data: { confirm: "Remove #{mr.resident.name} from this meal?" } }
          end
        end
      end
      unless meal.reconciled?
        candidates = Resident.where.not(id: meal.meal_residents.select(:resident_id))
                             .order(:name)
        form action: admin_meal_meal_residents_path(meal), method: :post do
          input type: :hidden, name: 'authenticity_token', value: form_authenticity_token
          text_node select_tag('meal_resident[resident_id]',
                               options_from_collection_for_select(candidates, :id, :name),
                               include_blank: 'Select a resident', required: true)
          input type: :submit, value: 'Add attendee'
        end
      end
    end

    # What settlement recorded for this meal: one line per bill, attendance,
    # and guest, written once inside the settlement transaction. Only a
    # reconciled meal has lines, and a meal reconciled before 2026-08-02 has
    # none on purpose (the backfill decision in
    # docs/money-path-observability.md).
    if meal.reconciled?
      panel 'Settlement line items' do
        lines = meal.meal_charges.includes(:resident)
                    .sort_by { |charge| [charge.kind, charge.resident.name] }
        settlement_lines_table(lines, first_column: :resident)
      end
    end

    # Corrections made after the meal was settled (ADR 0011 rule 6). The
    # line items above are what it was settled at; each correction says
    # what changed and who owes or is owed a different amount, and which
    # settlement carries it.
    corrections = meal.meal_corrections.includes(:reconciliation, :admin_user, lines: :resident).to_a
    if corrections.any?
      panel "Corrections (#{corrections.size})" do
        residents = CorrectionWords.residents_named_in(corrections)
        corrections.each do |correction|
          h4 do
            carrier = correction.reconciliation
            if carrier
              text_node 'Carried by '
              text_node link_to("the settlement of #{carrier.date.strftime('%b %-d, %Y')}",
                                admin_reconciliation_path(carrier))
            else
              text_node 'Waits for the next settlement'
            end
          end
          meal_correction_details(correction, residents: residents)
        end
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :date, as: :datepicker
      # Only on the New Meal form, which makes one-off meals (#100). The
      # options and the script that picks one by date: RotationChoicesHelper.
      # A date after the last rotation is refused on save (#143).
      if f.object.new_record?
        f.input :rotation, collection: rotation_choices, include_blank: 'Choose a rotation',
                           hint: 'When the date is inside a rotation, that rotation is chosen for you. ' \
                                 'For a date between two rotations, choose one yourself. ' \
                                 'A date after the last rotation is refused.'
      end
      f.input :closed
      f.input :max if f.object.closed
    end
    f.inputs do
      f.has_many :guests, allow_destroy: true, heading: 'Guests', new_record: true do |g|
        g.input :_destroy, as: :hidden
        # Every price a guest can have, and no other (Multiplier::GUEST_PRICES),
        # so the menu always shows the stored one and a save sends it back
        # unchanged. A new guest is an adult. On a closed meal, a guest who
        # was there when it closed keeps its price and its host
        # (ClosedMealAttendanceFreeze).
        g.input :multiplier, label: 'Price Category', as: :select, include_blank: false,
                             collection: Multiplier::GUEST_PRICES.map { |price| [Multiplier.label(price), price] }
        g.input :resident, label: 'Host',
                           collection: Resident.order(:name)
      end
    end

    f.actions
    # Every attribute, not only :base: a refused nested guest puts its
    # sentence on :guests, and with no arguments this would show nothing.
    f.semantic_errors(*f.object.errors.attribute_names)
  end
end
