# frozen_string_literal: true

ActiveAdmin.register Community do
  # MENU
  menu label: 'Community'

  # STRONG PARAMS
  permit_params :name, :cap, :slug, :timezone

  # CONFIG
  config.filters = false

  # ACTIONS
  # `new` is enabled so the very first Community can be created via the UI on
  # a fresh deployment. The model's enforce_singleton validation blocks a
  # second creation attempt, so we don't need to hide the button — an operator
  # who clicks "New" post-setup just gets a validation error.
  actions :all, except: %i[destroy]

  controller do
    # For show/edit/update, coerce any ID param back to the singleton record.
    # Skipped for new/create (find_resource isn't called for those actions).
    def find_resource
      Community.instance
    end
  end

  # INDEX
  index do
    column :name
    column :cap do |community|
      number_to_currency(community.cap) if community.capped?
    end
    column :slug
    column :timezone

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :id
      row :name
      row :cap do |community|
        number_to_currency(community.cap) if community.capped?
      end
      row :slug
      row :timezone
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :name
      f.input :cap, label: 'Cap ($)'
      f.input :slug if f.object.persisted?
      f.input :timezone,
              as: :select,
              collection: Community::SUPPORTED_TIMEZONES.map { |name, iana| [name, iana] }
    end

    f.actions
    f.semantic_errors
  end
end
