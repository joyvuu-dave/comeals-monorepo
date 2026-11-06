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

  # The link that makes the waiting address the resident's email
  # (EmailChange). Sent to the new address, so opening it shows the
  # person reads that inbox. The token goes after the #, like a reset
  # token's.
  def email_change_link_email(resident, token)
    @resident = resident
    @new_email = resident.pending_email
    @url = "#{root_url}/confirm-email#token=#{token}"
    mail(to: @new_email, subject: 'Confirm your new email')
  end

  # Sent to the old address when a change is asked for. Changing the
  # email asks for no password, so this is how a person learns that
  # someone else asked, from a device they left signed in.
  def email_change_notice_email(resident, old_email)
    @resident = resident
    @new_email = resident.pending_email
    mail(to: old_email, subject: 'Your Comeals email is being changed')
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
