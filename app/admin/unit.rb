# typed: false
# frozen_string_literal: true

ActiveAdmin.register Unit do
  # STRONG PARAMS
  permit_params :name

  # CONFIG
  config.filters = false
  config.sort_order = 'name_asc'

  # ACTIONS
  # Destroy is allowed. The model refuses to delete a unit that still has
  # residents (restrict_with_error), so only an empty unit — one created by
  # mistake — can actually be removed.
  actions :all

  controller do
    include RefusedDestroyMessage
  end

  # ADR 0011 rule 7: a unit's balance counts the people who live in it
  # now. The people who have moved out are on a line of their own, so the
  # units and it add up to $0.00.
  sidebar 'Moved out', only: :index do
    moved_out = Unit.moved_out_balance
    para do
      text_node 'Everyone who has moved out, together: '
      text_node balance_tag(moved_out)
    end
    text_node settlement_totals_tag(Unit.all.map(&:balance) + [moved_out], 'units')
  end

  # INDEX
  index do
    column 'Unit', :name
    # balance_tag turns the stored sign into words — see BalanceDisplayHelper.
    column :balance, sortable: false do |unit|
      balance_tag(unit.balance)
    end

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :name
      row :balance do |unit|
        balance_tag(unit.balance)
      end
      table_for unit.residents.active.order(:name) do
        column 'Active Residents' do |resident|
          link_to resident.name, admin_resident_path(resident)
        end
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :name
    end

    f.actions
    f.semantic_errors
  end
end
