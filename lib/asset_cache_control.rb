# frozen_string_literal: true

# Marks files under /assets/ and /vite-assets/ as cacheable for a year.
#
# Every file in those two directories has a content hash in its name
# (Vite writes the SPA to /vite-assets/, Sprockets writes ActiveAdmin to
# /assets/ — separate directories because Vite deletes everything in its
# own assets directory on each build, see vite.config.mjs), so the
# content behind a given URL can never change — a deploy changes the
# filename instead, and the HTML that names it is never cached. Files
# elsewhere in public/ (manifest.json, icons) keep their names across
# deploys, so they must not get this header.
#
# The text/html check matters: when an /assets/ URL names a file that no
# longer exists, the SPA catch-all route answers it with the app page and
# status 200. That response must stay uncached, or the browser would keep
# serving HTML at that URL for a year.
class AssetCacheControl
  HEADER = 'public, max-age=31536000, immutable'

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    if env['PATH_INFO'].start_with?('/assets/', '/vite-assets/') &&
       status == 200 &&
       !headers['content-type'].to_s.start_with?('text/html')
      headers['cache-control'] = HEADER
    end

    [status, headers, body]
  end
end
