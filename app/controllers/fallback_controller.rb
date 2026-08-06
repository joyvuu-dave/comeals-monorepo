# frozen_string_literal: true

class FallbackController < ActionController::API
  # public/index.html is where vite build writes it. The static file
  # server never serves it on its own — see public_file_server.index_name
  # in config/application.rb — so every request for it routes here.
  def index
    send_file Rails.public_path.join('index.html'),
              type: 'text/html', disposition: 'inline'
  end

  def vite_manifest
    path = Rails.public_path.join('.vite/manifest.json')
    if path.exist?
      response.headers['Cache-Control'] = 'no-cache'
      send_file path, type: 'application/json', disposition: 'inline'
    else
      head :not_found
    end
  end
end
