# typed: true
# frozen_string_literal: true

class FallbackController < ActionController::API
  # public/index.html is where vite build writes it. The static file
  # server never answers / with it — see public_file_server.index_name
  # in config/application.rb — and /index.html goes to / (SpaPageRedirect),
  # so every request for the page routes here.
  # The page goes out with this app's keys in it (PageSettings, #257).
  def index
    page = PageSettings.fill(
      Rails.public_path.join('index.html').read,
      PageSettings.values(vars: ENV.to_h, env: Rails.env)
    )
    send_data page, type: 'text/html', disposition: 'inline'
  end

  # Every address on the resident site that is not a page of the app
  # (config/routes.rb, AppPages): the plain 404 page, the same file
  # Rails sends for a missing admin page. no-store, so that a page left
  # out of routes.json by mistake shows as soon as it is added back,
  # not when a browser or a proxy lets a kept 404 go. It reads no
  # database. inline, because send_file's default is attachment, which
  # makes a browser save the page instead of showing it. send_file reads
  # the type, text/html, from the file's name.
  def not_found
    no_store
    send_file Rails.public_path.join('404.html'), disposition: 'inline', status: :not_found
  end
end
