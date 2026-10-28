# typed: true
# frozen_string_literal: true

class FallbackController < ActionController::API
  # public/index.html is where vite build writes it. The static file
  # server never serves it on its own — see public_file_server.index_name
  # in config/application.rb — so every request for it routes here.
  # The page goes out with this app's keys in it (PageSettings, #257).
  def index
    page = PageSettings.fill(
      Rails.public_path.join('index.html').read,
      PageSettings.values(vars: ENV.to_h, env: Rails.env)
    )
    send_data page, type: 'text/html', disposition: 'inline'
  end
end
