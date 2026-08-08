# frozen_string_literal: true

ActiveAdmin.register Resident do
  # STRONG PARAMS
  permit_params :name, :multiplier, :unit_id, :community_id, :email, :password, :vegetarian, :can_cook, :active,
                :birthday

  # CONFIG
  filter :active
  config.sort_order = 'name_asc'

  # ACTIONS
  # Destroy is allowed. The model refuses to delete a resident who has ledger
  # rows — bills, attendance, guests, or settled balances (restrict_with_error).
  # Only a resident created by mistake, with no ledger history, can actually
  # be removed. Everyone else is retired with the active flag.
  actions :all

  # On a refused delete, show the model's own error ("Cannot delete record
  # because dependent bills exist") instead of the generic
  # "could not be destroyed" flash.
  controller do
    # The index sorts by balance, and ORDER BY can only use a column that is
    # in the query — the balance lives in resident_balances, so join it.
    # left_joins, not joins: a resident created since the last daily
    # billing:recalculate run has no balance row yet and must not drop off
    # the page.
    def scoped_collection
      super.left_joins(:resident_balance)
    end

    def destroy
      destroy! do |_success, failure|
        failure.html do
          flash[:alert] = resource.errors.full_messages.to_sentence
          redirect_to collection_path
        end
      end
    end
  end

  # INDEX
  index do
    column :name
    column :birthday
    column 'Price Category', :multiplier, sortable: :multiplier do |resident|
      price_category_label(resident.multiplier)
    end
    column :unit
    column :can_cook
    column :active
    # balance_tag turns the stored sign into words — see BalanceDisplayHelper.
    # Sorting uses the joined resident_balances.amount (see scoped_collection
    # above). Residents with no balance row yet sort as NULL, which Postgres
    # puts last on ascending.
    column 'Balance', sortable: 'resident_balances.amount' do |resident|
      balance_tag(resident.balance)
    end

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :id
      row :name
      row :birthday
      row('Category') { |r| price_category_label(r.multiplier) }
      row :unit
      row :can_cook
      row :active
      row :email
      row :vegetarian
      table_for resident.meals.includes(:bills, :meal_residents, :guests, :meal_charges).order(:date) do
        column 'Meals Attended' do |meal|
          link_to meal.date, admin_meal_path(meal)
        end
        column 'Unit Cost' do |meal|
          meal_cost_cell(meal, :unit_cost)
        end
      end
      table_for resident.bills.all do
        column 'Bills' do |bill|
          link_to bill.meal.date, admin_bill_path(bill)
        end
        column 'Amount' do |bill|
          number_to_currency(bill.amount) unless bill.amount.zero?
        end
      end
      # Preloads are what MealCostSummary's header asks of callers that
      # show many meals — same list as the meals table above.
      table_for resident.guests.includes(meal: %i[bills meal_residents guests meal_charges]) do
        column 'Meal' do |guest|
          link_to guest.meal.date, admin_meal_path(guest.meal)
        end
        column 'Price Category', :multiplier do |guest|
          price_category_label(guest.multiplier)
        end
        column 'Unit Cost' do |guest|
          meal_cost_cell(guest.meal, :unit_cost)
        end
      end
    end

    # The statement: what each settled balance is made of, one section per
    # reconciliation. Driven by reconciliation_balances rather than the
    # charges, so a settlement with no line items still gets a section — a
    # reconciliation settled before 2026-08-02 has no lines on purpose (the
    # backfill decision in docs/money-path-observability.md), and that must
    # read as "not recorded", not as zero charges.
    #
    # This panel sits outside the attributes_table above for the same reason
    # as the attendance panel in app/admin/meal.rb: content like this cannot
    # nest inside a table body.
    panel 'Settlement statement' do
      balances = resident.reconciliation_balances.includes(:reconciliation)
                         .sort_by { |balance| balance.reconciliation.date }.reverse

      if balances.empty?
        para 'No settled balances yet.'
      else
        # One query for every line, grouped in Ruby, instead of one query per
        # reconciliation.
        lines_by_reconciliation = resident.meal_charges
                                          .includes(meal: :reconciliation)
                                          .group_by { |charge| charge.meal.reconciliation_id }

        balances.each do |balance|
          reconciliation = balance.reconciliation
          h3 do
            text_node link_to("#{reconciliation.date} to #{reconciliation.end_date}",
                              admin_reconciliation_path(reconciliation))
            text_node ' — settled: '
            text_node balance_tag(balance.amount)
          end

          lines = (lines_by_reconciliation[reconciliation.id] || []).sort_by { |charge| charge.meal.date }
          settlement_lines_table(lines, first_column: :meal)
        end

        para 'Credited amounts minus charged amounts come to within one cent of the settled ' \
             'amount. Line amounts are stored at full precision; the settled amount is ' \
             'rounded to cents by largest-remainder allocation.'
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :name
      f.input :birthday, as: :datepicker,
                         datepicker_options: {
                           change_month: true,
                           change_year: true,
                           year_range: "1900:#{Time.zone.now.year}"
                         }
      f.input :email
      f.input :password if f.object.new_record?
      f.input :vegetarian
      f.input :multiplier, label: 'Price Category', as: :radio, collection: [['Adult', 2], ['Child', 1]]
      f.input :unit, collection: Unit.order(:name)
      f.input :can_cook
      f.input :active
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
    end
    f.label 'Note: passwords can be reset through the resident login page'
    f.actions
    f.semantic_errors
  end
end
