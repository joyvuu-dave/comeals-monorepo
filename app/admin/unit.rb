# frozen_string_literal: true

ActiveAdmin.register Unit do
  # STRONG PARAMS
  permit_params :name, :community_id

  # CONFIG
  config.filters = false
  config.sort_order = 'name_asc'

  # ACTIONS
  actions :all, except: [:destroy]

  # INDEX
  index do
    column 'Unit', :name
    column :balance do |unit|
      number_to_currency(unit.balance) unless unit.balance.zero?
    end

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :name
      row :balance do |unit|
        number_to_currency(unit.balance) unless unit.balance.zero?
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
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
    end

    f.actions
    f.semantic_errors
  end
end
