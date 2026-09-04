# typed: true

# Devise defines these at boot from the `devise_for :admin_users` route and
# the `devise` call in AdminUser. Tapioca has no compiler for Devise, so
# they are declared here by hand. Keep this file in step with those two
# places.
class ActiveRecord::Base
  sig { params(modules: Symbol, options: T.untyped).void }
  def self.devise(*modules, **options); end
end

class ApplicationController
  sig { params(opts: T.untyped).void }
  def authenticate_admin_user!(opts = {}); end

  sig { returns(T.nilable(AdminUser)) }
  def current_admin_user; end
end
