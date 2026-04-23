# frozen_string_literal: true

ActiveAdmin.register Meal do
  # STRONG PARAMS
  permit_params :date, :closed, :max, :community_id,
                guests_attributes: %i[id multiplier resident_id meal_id _destroy], attendee_ids: []

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
      table_for meal.attendees.order(:name) do
        column 'Residents Attendance' do |resident|
          link_to resident.name, admin_resident_path(resident)
        end
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
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :date, as: :datepicker
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
      f.input :closed
      f.input :max if f.object.closed
      f.input :attendees, as: :check_boxes, label: 'Attendees', collection: Resident.includes(:unit).order('units.name ASC').map { |r|
        ["#{r.name} - #{r.unit.name}", r.id]
      }
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
