# typed: true
# frozen_string_literal: true

class ResidentMailer < ApplicationMailer
  # The token comes from PasswordReset, which stores only its digest, so
  # the resident row cannot give it back. It goes after the #: a browser
  # never sends that part of a link to the server, so the token is in no
  # request line and no log (Api::V1::ResidentsController).
  def password_reset_email(resident, token)
    @resident = resident
    @url = "#{root_url}/reset-password#token=#{token}"
    mail(to: @resident.email, subject: 'Reset your password')
  end

  def rotation_signup_email(resident, rotation, open_meal_dates, community)
    @resident = resident
    @rotation  = rotation
    @community = community
    @open_meal_dates = open_meal_dates
    @url = root_url
    mail(to: @resident.email, subject: 'Sign up to Cook')
  end

  def new_rotation_email(resident, rotation, community)
    @rotation  = rotation
    @community = community

    @url = root_url
    mail(to: resident.email, subject: 'New Rotation Posted')
  end
end
