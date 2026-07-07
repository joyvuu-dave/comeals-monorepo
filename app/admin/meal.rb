# frozen_string_literal: true

ActiveAdmin.register Meal do
  # STRONG PARAMS
  # attendee_ids is deliberately absent: ids-assignment on the through
  # association removes MealResident rows without their audit hooks or
  # closed/reconciled guards running per row (issue #7). Attendance is
  # managed through the API, which operates on individual rows.
  permit_params :date, :closed, :max, :community_id,
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
      end_of_association_chain.includes(:community, :bills)
    end

    def block_if_reconciled
      return unless resource.reconciled?

      redirect_to admin_meal_path(resource),
                  alert: 'This meal is reconciled and cannot be modified.'
    end
  end

  # INDEX
  index do
    column :id
    column :date
    column :attendees_count, sortable: false
    column :closed
    column :max
    column :subsidized?
    column :max_cost do |meal|
      number_to_currency(meal.max_cost) if meal.capped?
    end
    column :total_cost do |meal|
      number_to_currency(meal.total_cost) unless meal.total_cost.zero?
    end
    column :unit_cost do |meal|
      number_to_currency(meal.unit_cost) unless meal.unit_cost.zero?
    end
    column 'Number of Bills', :bills_count
    column :reconciled?, sortable: false

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :date
      row :community
      row :closed
      row :max
      row :subsidized?
      row :total_cost do |meal|
        number_to_currency(meal.total_cost) unless meal.total_cost.zero?
      end
      row :unit_cost do |meal|
        number_to_currency(meal.unit_cost) unless meal.unit_cost.zero?
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
        candidates = Resident.where(community_id: meal.community_id)
                             .where.not(id: meal.meal_residents.select(:resident_id))
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
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :date, as: :datepicker
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
      f.input :closed
      f.input :max if f.object.closed
    end
    f.inputs do
      f.has_many :guests, allow_destroy: true, heading: 'Guests', new_record: true do |g|
        g.input :_destroy, as: :hidden
        g.input :multiplier, label: 'Price Category', as: :select, include_blank: false,
                             collection: [['Adult', 2], ['Child', 1]]
        g.input :resident, label: 'Host',
                           collection: Resident.order(:name)
        g.input :meal_id, as: :hidden, input_html: { value: meal.id }
      end
    end

    f.actions
    f.semantic_errors
  end
end
