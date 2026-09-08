# typed: true
# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM_ADDRESS', 'admin@comeals.com')
  layout 'mailer'

  # Where the SPA and the admin live, for links in mail. Set per
  # environment in config/environments (config.x.root_url and
  # config.x.admin_root_url).
  def root_url
    Rails.configuration.x.root_url
  end

  def root_admin_url
    Rails.configuration.x.admin_root_url
  end
end
