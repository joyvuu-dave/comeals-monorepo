# typed: true
# frozen_string_literal: true

module AdminUsers
  # The admin's forgotten-password pages: Devise's, through ActiveAdmin,
  # with one change. The reset email carries the token after the # in its
  # link (app/views/devise/mailer/reset_password_instructions.html.erb),
  # so it is never part of a request line. Heroku's router logs every
  # request line with its query, and Rails cannot filter that log, so a
  # token in the query would be written there.
  #
  # The edit page's script reads the token from the address bar
  # (app/views/admin_users/passwords/edit.html.erb), and the form sends it
  # in the body of PUT /password, which Rails logs as [FILTERED].
  #
  # The class is named PasswordsController, like ActiveAdmin's, because
  # ActiveAdmin's page links check the controller name: on "passwords"
  # pages they leave out the "Forgot your password?" link.
  class PasswordsController < ActiveAdmin::Devise::PasswordsController
    OLD_LINK = 'This reset link is the old kind, which no longer works. Enter your email below to ask for a new one.'

    protected

    # Devise runs this before the edit page, to send away a request with
    # no token in the query. Now the page never gets the token in the
    # request, so this does the opposite: a link mailed before the token
    # moved after the # has it in the query. The router has logged that
    # request line by the time it gets here, so the page does not use the
    # token: it sends the admin to ask for a new link, and asking replaces
    # the old token.
    def assert_reset_token_passed
      return unless params.key?(:reset_password_token)

      redirect_to new_password_path(resource_name), alert: OLD_LINK
    end
  end
end
