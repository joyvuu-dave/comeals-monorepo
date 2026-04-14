# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM_ADDRESS', 'admin@comeals.com')
  layout 'mailer'

  def root_url
    @root_url ||= Rails.env.production? ? 'https://comeals.com' : 'http://localhost:3036'
  end

  def root_admin_url
    @root_admin_url ||= Rails.env.production? ? 'https://comeals.com/admin' : 'http://localhost:3000/admin'
  end
end
