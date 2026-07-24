# frozen_string_literal: true

ActiveAdmin.register Unit do
  # STRONG PARAMS
  permit_params :name, :community_id

  # CONFIG
  config.filters = false
  config.sort_order = 'name_asc'

  # ACTIONS
  # Destroy is allowed. The model refuses to delete a unit that still has
  # residents (restrict_with_error), so only an empty unit — one created by
  # mistake — can actually be removed.
  actions :all

  # On a refused delete, show the model's own error ("Cannot delete record
  # because dependent residents exist") instead of the generic
  # "could not be destroyed" flash.
  controller do
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
