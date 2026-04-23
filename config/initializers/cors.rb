# frozen_string_literal: true

# CORS policy — required for the React Native mobile app (Expo web target) and
# any non-same-origin web client. The main SPA is served same-origin by Rails
# and never triggers CORS, so this does nothing for it.
#
# Origins are deliberately narrow. Add new ones explicitly rather than
# broadening with `*` — Authorization headers and cookies are credentials.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(
      # Expo dev server (web target + tooling)
      'http://localhost:8081', 'http://127.0.0.1:8081',
      # Expo Go capacitor-style loopback used by some SDK versions
      'http://localhost:19006', 'http://127.0.0.1:19006'
    )

    resource '/api/*',
             headers: :any,
             methods: %i[get post patch put delete options],
             expose: %w[Content-Type],
             credentials: false,
             max_age: 600
  end
end
