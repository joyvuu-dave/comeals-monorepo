# frozen_string_literal: true

# During bootstrap (AdminUser exists but Community does not), redirect every
# ActiveAdmin page to the Community new form. Without this guard a bootstrap
# admin could navigate to /admin/residents or /admin/bills, where index
# actions render empty lists and nav clicks would 500 once code dereferenced
# Community.instance.
#
# Applies to ActiveAdmin::BaseController so both resource controllers and
# register_page controllers (e.g. Dashboard) inherit it. Devise's sign-in
# controllers inherit from Devise, not ActiveAdmin, so they are unaffected.
Rails.application.config.to_prepare do
  ActiveAdmin::BaseController.class_eval do
    before_action :require_community_for_bootstrap

    private

    def require_community_for_bootstrap
      return if Community.exists?
      # Exempt the Community new/create actions — that's the one doorway out
      # of the bootstrap state. Without this exemption we'd redirect-loop.
      return if controller_name == 'communities' && %w[new create].include?(action_name)

      redirect_to(new_admin_community_path,
                  notice: 'Create your community to finish setup.')
    end
  end
end
