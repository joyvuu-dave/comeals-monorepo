# frozen_string_literal: true

class SuperuserAdapter < ActiveAdmin::AuthorizationAdapter
  def authorized?(action, _subject = nil)
    return true if action == :read
    return true if %i[create new].include?(action) && user.superuser?
    return true if %i[update edit].include?(action) && user.superuser?
    return true if action == :destroy && user.superuser?
    return true if action == :update_meals && user.superuser?

    false
  end
end
