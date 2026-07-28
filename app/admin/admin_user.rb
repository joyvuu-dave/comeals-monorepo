# frozen_string_literal: true

ActiveAdmin.register AdminUser do
  # MENU
  menu label: 'Admins'

  # STRONG PARAMS
  # :superuser is permitted so the flag can be granted through the UI at all —
  # before this it was missing, so the form silently dropped it and the tier
  # could only be set from a console. The controller below refuses the
  # parameter rather than dropping it when the actor may not set it, because a
  # silent drop looks like success.
  permit_params :email, :password, :password_confirmation, :community_id, :superuser

  # CONFIG
  config.filters = false

  controller do
    # SuperuserAdapter already restricts every AdminUser write to superusers.
    # This is the narrower rule it cannot express, because authorization there
    # is per resource and this is about one field and who is acting:
    #
    #   - Only a superuser may set the flag. The adapter already refuses this,
    #     so this check is a second one on the same rule.
    #   - Nobody may demote themselves. The model refuses this only when they
    #     are the LAST superuser, which is the rule that protects the
    #     community. This is the softer rule that protects the person: with
    #     seven superusers, demoting yourself is recoverable but still almost
    #     never what you meant to click.
    before_action :refuse_unauthorized_superuser_change, only: %i[create update]

    private

    def refuse_unauthorized_superuser_change
      requested = params.dig(:admin_user, :superuser)
      return if requested.nil?

      if !current_active_admin_user&.superuser?
        redirect_to resource_or_collection_path,
                    alert: 'Only a superuser may grant or remove superuser access.'
      elsif demoting_self?(requested)
        redirect_to resource_or_collection_path,
                    alert: 'You cannot remove your own superuser access. Ask another superuser to do it.'
      end
    end

    def demoting_self?(requested)
      action_name == 'update' &&
        resource.id == current_active_admin_user&.id &&
        resource.superuser? &&
        !ActiveModel::Type::Boolean.new.cast(requested)
    end

    def resource_or_collection_path
      action_name == 'update' ? admin_admin_user_path(resource) : admin_admin_users_path
    end
  end

  index do
    selectable_column
    id_column
    column :email
    column :superuser
    column :current_sign_in_at
    column :sign_in_count
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :email
      row :superuser
      row :current_sign_in_at
      row :sign_in_count
      row :created_at
    end
  end

  form do |f|
    f.inputs 'Admin Details' do
      f.input :email
      f.input :password
      f.input :password_confirmation
      # Hidden rather than disabled when the actor may not change it, so the
      # form does not post a value the controller would then have to refuse.
      if current_active_admin_user&.superuser? && !(f.object.persisted? &&
                                                   f.object.id == current_active_admin_user.id)
        f.input :superuser,
                hint: 'Superusers may settle reconciliations, edit bills and attendance, and ' \
                      'grant admin access. Other admins may do everything except touch the ledger.'
      end
      f.input :community_id, input_html: { value: Community.instance.id }, as: :hidden
    end
    f.actions
  end
end
