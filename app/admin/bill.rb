# frozen_string_literal: true

ActiveAdmin.register Bill do
  # STRONG PARAMS
  permit_params :meal_id, :resident_id, :community_id, :amount

  # CONFIG
  filter :resident, as: :select, collection: proc { Resident.order(:name).pluck('name', 'id') }, include_blank: true
  filter :meal_reconciliation_id, as: :select, collection: proc {
    Reconciliation.pluck('date', 'id')
  }, include_blank: true
  config.current_filters = false
  config.sort_order = 'meals.date_desc'

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
    # a racing write waits for the settlement and is then refused with an
    # exception. What is left here is a cosmetic race — a user can see this
    # redirect's friendly message or the trigger's blunt one, depending on
    # timing. Both refuse. Read docs/adr/0003-concurrency-on-the-money-path.md
    # before touching this.
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
    column Meal.model_name.human, :date, sortable: 'meals.date'
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
      f.input :meal, label: 'Common Meal Date', collection: Meal.order(date: :desc).map { |i|
        [i.date, i.id]
      }
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
      f.input :resident_id, as: :select, include_blank: false, label: 'Cook', collection: Resident.includes(:unit).adult.order('units.name ASC').map { |r|
        ["#{r.name} - #{r.unit.name}", r.id]
      }
      f.input :amount, label: '$'
    end

    f.actions
    f.semantic_errors
  end
end
