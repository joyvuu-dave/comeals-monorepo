# typed: false
# frozen_string_literal: true

ActiveAdmin.register Bill do
  # STRONG PARAMS
  # The cook and the meal are set on the new bill form. The edit form does
  # not send them, and a request that does is refused in words by the
  # model (Bill::COOK_AND_MEAL_FIXED), so they stay permitted here.
  permit_params :meal_id, :resident_id, :amount, :no_cost

  # The edit form says "delete this bill and add a new one" to fix a wrong
  # cook or meal, so the edit page offers Delete too. ActiveAdmin puts it
  # only on the show page by itself.
  action_item :destroy_from_edit, only: :edit, if: -> { authorized?(ActiveAdmin::Auth::DESTROY, resource) } do
    link_to 'Delete Bill', resource_path(resource), method: :delete,
                                                    data: { confirm: 'Are you sure you want to delete this?' }
  end

  # CONFIG
  filter :resident, as: :select, collection: proc { Resident.order(:name).pluck('name', 'id') }, include_blank: true
  filter :meal_reconciliation_id, as: :select, collection: proc {
    Reconciliation.pluck('date', 'id')
  }, include_blank: true
  config.current_filters = false
  config.sort_order = 'meals.date_desc'
  # Three index columns sort by a column of a joined table (scoped_collection
  # below joins them). AdminOrderClause allows a key on another table only
  # when the page declares it here, and each block writes the SQL for it.
  order_by('meals.date') { |clause| "meals.date #{clause.order}" }
  order_by('residents.name') { |clause| "residents.name #{clause.order}" }
  order_by('units.name') { |clause| "units.name #{clause.order}" }

  controller do
    before_action { @page_title = 'Cooking Slots' }
    # Reconciled meals are immutable. Redirect rather than relying on the
    # model-layer abort, which would render a confusing form error.
    #
    # This check is a plain, non-locking read, and this resource never takes
    # the meal row lock that the API's with_meal_lock takes. So it can be
    # wrong: `reconciliations:create` may settle the meal between this read
    # and the write. That used to lose money silently (issue #43) — the write
    # landed on a meal that was reconciled by the time it finished, and
    # billing:recalculate skipped it because that task only sums unreconciled
    # meals.
    #
    # It no longer does. The database catches it now, from any path: the
    # settlement holds FOR UPDATE on every meal it claims, and the child-write
    # trigger's lookups are locking reads (20260727120000), so
    # a racing write waits for the settlement and is then refused. What is
    # left here is which sentence the person sees, by timing: this
    # redirect's, the model guard's ("Meal has been reconciled.", it reads
    # the meals table), or the conflict alert when the settlement commits
    # during the save. All three refuse. Read
    # docs/adr/0003-concurrency-on-the-money-path.md before touching this.
    before_action :block_if_reconciled, only: %i[edit update destroy]

    def scoped_collection
      # eager_load (not includes) guarantees LEFT OUTER JOINs, which is required
      # because index columns sort on associated tables: meals.date, residents.name,
      # units.name. includes uses a heuristic to choose between separate queries and
      # JOINs — if it chooses separate queries, ORDER BY on an associated table's
      # column will fail silently or error.
      # preload (not eager_load) for has_many associations to avoid cartesian product
      end_of_association_chain
        .eager_load(:meal, :resident, resident: :unit)
        .preload(meal: %i[meal_residents guests])
    end

    def block_if_reconciled
      return unless resource.reconciled?

      redirect_to admin_bill_path(resource),
                  alert: 'This bill belongs to a reconciled meal and cannot be modified.'
    end
  end

  # INDEX
  index do
    column Meal.model_name.human, :date, sortable: 'meals.date' do |bill|
      l(bill.date, format: :admin)
    end
    column 'Attendees' do |bill|
      bill.meal.meal_residents.size + bill.meal.guests.size
    end
    column '$', :amount do |bill|
      number_to_currency(bill.amount) unless bill.amount.zero?
    end
    column :resident, sortable: 'residents.name'
    column :unit, sortable: 'units.name'

    actions
  end

  # FORM
  form do |f|
    f.inputs do
      if f.object.new_record?
        f.input :meal, label: 'Common Meal Date', collection: Meal.order(date: :desc).map { |i|
          [I18n.l(i.date, format: :admin), i.id]
        }
        f.input :resident_id, as: :select, include_blank: false, label: 'Cook', collection: Resident.includes(:unit).adult.order('units.name ASC').map { |r|
          ["#{r.name} - #{r.unit.name}", r.id]
        }
      else
        # A saved bill keeps its cook and its meal (Bill::COOK_AND_MEAL_FIXED),
        # so the edit form shows them as text. Read from the database, not
        # from the form's record: after a refused save, the record holds
        # the cook or meal the request asked for, which the bill never got.
        meal = Meal.find(f.object.meal_id_in_database)
        cook = Resident.includes(:unit).find(f.object.resident_id_in_database)
        # tag.label, not Arbre's label: inside a form, Arbre's label is the
        # form builder's, which reads its text as a field name and writes
        # "Common meal date".
        li class: 'input', id: 'bill_meal_input' do
          text_node helpers.tag.label('Common Meal Date', class: 'label')
          span I18n.l(meal.date, format: :admin)
        end
        li class: 'input', id: 'bill_resident_input' do
          text_node helpers.tag.label('Cook', class: 'label')
          span "#{cook.name} - #{cook.unit.name}"
          para 'To change the cook or the meal, delete this bill and add a new one.', class: 'inline-hints'
        end
      end
      # The column is DECIMAL(12,8), so the raw value renders as "16.0" —
      # render it as money instead (MoneyFieldHelper). A new bill's amount
      # is the column default 0, which renders blank so the cook's real
      # cost must be typed. (A jQuery line used to clear the zero; its
      # field id went stale and it silently stopped working.)
      f.input :amount,
              label: '$',
              input_html: {
                value: helpers.money_field_value(f.object.amount, blank_when_zero: f.object.new_record?)
              }
      # The same switch as on the cook's row of the meal page. Without it
      # here, a no-cost bill deleted and added again (the way to fix a
      # wrong cook) came back as a $0 bill waiting for a cost. A bill
      # marked No cost has no amount, and the model refuses both in
      # words (Bill::NO_COST_MEANS_NO_AMOUNT), which the form shows.
      f.input :no_cost,
              label: 'No cost',
              hint: "Check this box when the cook spent nothing. A bill marked No cost can't have an amount."
    end

    f.actions
    f.semantic_errors
  end
end
