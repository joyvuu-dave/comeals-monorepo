# frozen_string_literal: true

Audited.config do |config|
  # One global method name, resolved per controller: API requests attribute
  # audits to the resident, ActiveAdmin requests to the admin user. Defined
  # on ApiController and ApplicationController respectively.
  config.current_user_method = :audited_user
end
