# frozen_string_literal: true

ActiveAdmin.register Reconciliation do
  menu label: 'Reconciliations'

  # CONFIG
  config.filters = false

  # Reconciliations are append-only settlement events: once created, the
  # cutoff, the swept meals, and the persisted balances are the record that
  # cooks were notified of and paid against. No edit, update, or destroy —
  # corrections settle as new entries in the next reconciliation (the model
  # enforces this too; see Reconciliation#reject_update / #reject_destroy).
  actions :index, :show, :new, :create

  permit_params :community_id, :end_date

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
      # Read-only record of the meals this settlement swept. Corrections are
      # never made by editing the set — they settle as new entries in the next
      # reconciliation.
      settled_meals = reconciliation.meals.includes(bills: :resident).order(:date)

      table_for settled_meals do
        column('Date') { |m| link_to m.date.to_s, admin_meal_path(m) }
        column('Cooks') do |m|
          cooks = m.bills.map(&:resident).uniq.sort_by(&:name)
          cooks.empty? ? '—' : safe_join(cooks.map { |c| link_to(c.name, admin_resident_path(c)) }, ', ')
        end
        column('Total Cost') { |m| number_to_currency(m.total_cost) }
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
      f.input :end_date, as: :datepicker,
                         hint: 'Settle all unreconciled meals on or before this date. ' \
                               'Must be before today — same-day meals may not have finished.'
    end
    f.actions
    f.semantic_errors
  end
end
