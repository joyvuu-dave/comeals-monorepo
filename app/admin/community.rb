# frozen_string_literal: true

ActiveAdmin.register Community do
  # MENU
  menu label: 'Community'

  # STRONG PARAMS
  permit_params :name, :cap, :slug, :timezone

  # CONFIG
  config.filters = false

  # ACTIONS
  # `new` and `create` stay routed so the very first Community can be created
  # through the UI on a fresh deployment. Once that row exists, SuperuserAdapter
  # refuses both — the "New Community" button is gone and the URLs are denied.
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
      f.input :cap,
              label: 'Cap ($)',
              hint: 'Most a meal can cost per multiplier unit. Leave blank for no cap. ' \
                    'The lowest cap you can set is $0.01.'
      f.input :slug if f.object.persisted?
      f.input :timezone,
              as: :select,
              collection: Community::SUPPORTED_TIMEZONES.map { |name, iana| [name, iana] }
    end

    f.actions
    f.semantic_errors
  end
end
