# frozen_string_literal: true

class FallbackController < ActionController::API
  def index
    send_file Rails.root.join('public', 'index.html'),
              type: 'text/html', disposition: 'inline'
  end

  def vite_manifest
    path = Rails.root.join('public', '.vite', 'manifest.json')
    if path.exist?
      response.headers['Cache-Control'] = 'no-cache'
      send_file path, type: 'application/json', disposition: 'inline'
    else
      head :not_found
    end
  end
end
