# frozen_string_literal: true

ActiveAdmin.register Reconciliation do
  menu label: 'Reconciliations'

  # CONFIG
  config.filters = false

  # Reconciliations are immutable settlement events. Destroying one silently
  # wipes its reconciliation_balances and un-assigns its meals, with no audit
  # trail. If un-settlement is ever needed it should be a deliberate rake task.
  actions :all, except: [:destroy]

  permit_params :community_id, :end_date

  # Update which meals are in this reconciliation. Receives a list of meal IDs
  # that should be in the reconciliation; diffs against current state and
  # adds/removes accordingly. Balances are recomputed once at the end.
  #
  # Eligible meals to add: unreconciled meals with date <= end_date.
  # Meals from other reconciliations cannot be moved here directly — they must
  # be removed from their current reconciliation first.
  member_action :update_meals, method: :patch do
    desired_ids = Array(params[:meal_ids]).to_set(&:to_i)
    current_ids = resource.meals.pluck(:id).to_set

    to_add = desired_ids - current_ids
    to_remove = current_ids - desired_ids

    ActiveRecord::Base.transaction do
      if to_add.any?
        eligible = Meal.where(id: to_add, reconciliation_id: nil)
                       .where(date: ..resource.end_date)
        if eligible.count != to_add.size
          redirect_to resource_path, alert: 'One or more selected meals are not eligible to be added.'
          raise ActiveRecord::Rollback
        end
        Meal.where(id: to_add).update_all(reconciliation_id: resource.id)
      end

      Meal.where(id: to_remove).update_all(reconciliation_id: nil) if to_remove.any?

      resource.persist_balances!
    end

    return if performed?

    redirect_to resource_path,
                notice: "Updated meals in reconciliation: #{to_add.size} added, #{to_remove.size} removed. Balances recomputed."
  end

  # INDEX
  index do
    column :date
    column :end_date
    column :number_of_meals, sortable: false
    actions
  end

  # SHOW
  show do
    attributes_table do
      row :date
      row :end_date
      row :number_of_meals
    end

    panel 'Settlement Balances' do
      balances = reconciliation.reconciliation_balances
                               .includes(resident: :unit)
                               .joins(resident: :unit)
                               .order('units.name, residents.name')

      table_for balances do
        column('Resident') { |rb| link_to rb.resident.name, admin_resident_path(rb.resident) }
        column('Unit') { |rb| rb.resident.unit.name }
        column('Balance') { |rb| number_to_currency(rb.amount) }
      end

      total = balances.sum(:amount)
      div class: 'settlement-total' do
        strong "Total: #{number_to_currency(total)}"
      end
    end

    panel 'Unit Balances' do
      unit_bals = reconciliation.unit_balances

      table_for unit_bals.to_a do
        column('Unit') { |(unit_id, unit_name), _| link_to unit_name, admin_unit_path(unit_id) }
        column('Balance') { |_, amount| number_to_currency(amount) }
      end

      total = unit_bals.values.sum(BigDecimal('0'))
      div class: 'settlement-total' do
        strong "Total: #{number_to_currency(total)}"
      end
    end

    panel 'Meals' do
      # Eligible meals: currently in this reconciliation OR unreconciled with
      # date on or before the cutoff. Check to include, uncheck to exclude.
      eligible_meals = Meal.where(community_id: reconciliation.community_id)
                           .where('reconciliation_id = :id OR (reconciliation_id IS NULL AND date <= :end_date)',
                                  id: reconciliation.id, end_date: reconciliation.end_date)
                           .includes(bills: :resident)
                           .order(:date)

      render partial: 'admin/reconciliations/meals_form',
             locals: { reconciliation: reconciliation, eligible_meals: eligible_meals }
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
      f.input :end_date, as: :datepicker, hint: 'Settle all unreconciled meals on or before this date'
    end
    f.actions
    f.semantic_errors
  end
end
