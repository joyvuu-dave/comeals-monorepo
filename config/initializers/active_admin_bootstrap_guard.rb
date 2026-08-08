# frozen_string_literal: true

# During bootstrap (AdminUser exists but Community does not), redirect every
# ActiveAdmin page to the Community new form. Without this guard a bootstrap
# admin could navigate to /residents or /bills, where index actions render
# empty lists and nav clicks would 500 once code dereferenced
# Community.instance. (ActiveAdmin is mounted at the root of the admin
# subdomain, so its paths carry no /admin prefix — the route helpers are
# still named *_admin_* because default_namespace is :admin.)
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
      # schedule_preview serves the new form's live meal-schedule preview,
      # so it has to work in the same doorway.
      return if controller_name == 'communities' && %w[new create schedule_preview].include?(action_name)

      redirect_to(new_admin_community_path,
                  notice: 'Create your community to finish setup.')
    end
  end
end
