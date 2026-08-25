# frozen_string_literal: true

ActiveAdmin.register Meal do
  # STRONG PARAMS
  # attendee_ids is deliberately absent: ids-assignment on the through
  # association removes MealResident rows without their audit hooks or
  # closed/reconciled guards running per row (issue #7). Attendance is
  # managed through the API, which operates on individual rows.
  permit_params :date, :closed, :max,
                guests_attributes: %i[id multiplier resident_id meal_id _destroy]

  # CONFIG
  filter :reconciliation_id_null, as: :select, collection: [['Yes', false], ['No', true]], include_blank: false,
                                  default: false, label: 'Reconciled?'
  config.sort_order = 'date_desc'

  controller do
    # Reconciled meals are immutable — block edit/update/destroy. Adding
    # attendees or guests via the nested form would otherwise be caught by the
    # child models' before_save guards, but the resulting transaction error is
    # a worse admin UX than a clean redirect.
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

    # On a refused delete (closed meal), show the model's own error instead
    # of the generic "could not be destroyed" flash. Reconciled meals never
    # reach this — block_if_reconciled redirects first.
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

    def destroy
      destroy! do |_success, failure|
        failure.html do
          flash[:alert] = resource.errors.full_messages.to_sentence
          redirect_to admin_meal_path(resource)
        end
      end
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
    column :reconciled?, sortable: false

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :date
      row :closed
      row :max
      row :subsidized? do |meal|
        MealCostSummary.for(meal)&.subsidized
      end
      row :total_cost do |meal|
        meal_cost_cell(meal, :total_cost)
      end
      row :unit_cost do |meal|
        meal_cost_cell(meal, :unit_cost)
      end
      table_for meal.guests.order(:created_at) do
        column 'Guests in Attendance' do |guest|
          li "Guest of #{guest.resident.name}"
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
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :date, as: :datepicker
      f.input :closed
      f.input :max if f.object.closed
    end
    f.inputs do
      f.has_many :guests, allow_destroy: true, heading: 'Guests', new_record: true do |g|
        g.input :_destroy, as: :hidden
        g.input :multiplier, label: 'Price Category', as: :select, include_blank: false,
                             collection: [['Adult', Multiplier::FULL], ['Child', Multiplier::HALF]]
        g.input :resident, label: 'Host',
                           collection: Resident.order(:name)
        g.input :meal_id, as: :hidden, input_html: { value: meal.id }
      end
    end

    f.actions
    # Every attribute, not only :base: a refused nested guest puts its
    # sentence on :guests, and with no arguments this would show nothing.
    f.semantic_errors(*f.object.errors.attribute_names)
  end
end
