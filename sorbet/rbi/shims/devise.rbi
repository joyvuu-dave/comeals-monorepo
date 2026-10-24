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

# Devise's controllers live in the gem's app/ folder, which Tapioca does
# not read, and the DSL RBI declares ActiveAdmin's subclasses of them
# (lib/active_admin/devise.rb) with no parent. So Sorbet saw
# AdminUsers::PasswordsController, a subclass of ActiveAdmin's, as a
# plain object. These lines give it the real parents
# (Devise.parent_controller is ApplicationController), the URL helpers
# Devise adds to every controller, and resource_name.
class DeviseController < ApplicationController
  include Devise::Controllers::UrlHelpers

  sig { returns(Symbol) }
  def resource_name; end
end

class Devise::PasswordsController < DeviseController; end

class ActiveAdmin::Devise::PasswordsController < Devise::PasswordsController; end
