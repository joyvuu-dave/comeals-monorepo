# typed: true
# frozen_string_literal: true

# Sends a request for /index.html to /. Rails' static file server would
# answer it with public/index.html as vite build wrote it, and that file
# has none of the app's keys: FallbackController puts them in as it sends
# the page (PageSettings, #257). The router never sees /index.html, so
# this runs before the static file server.
#
# 301, because the page has one address, /. The query string goes along.
# Rack promises both PATH_INFO and QUERY_STRING, as strings.
class SpaPageRedirect
  PATH = '/index.html'

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env.fetch('PATH_INFO') == PATH

    query = env.fetch('QUERY_STRING')
    [301, { 'location' => query.empty? ? '/' : "/?#{query}" }, []]
  end
end
