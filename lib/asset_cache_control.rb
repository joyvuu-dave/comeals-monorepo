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
#
# /service-worker.js is the opposite case, so it gets 'no-cache': its
# name never changes, and it is the no-op worker that neutralizes the old
# caching worker on returning users' browsers (see the comment in the
# file itself). With no header, a browser may cache it by heuristic.
# Modern browsers skip the HTTP cache when they check a service worker
# script for updates, so this only matters for older ones — but the whole
# point of that file is to reach exactly the browsers still holding old
# state, so it must not rely on modern behavior.
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
    elsif env['PATH_INFO'] == '/service-worker.js' && status == 200
      headers['cache-control'] = 'no-cache'
    end

    [status, headers, body]
  end
end
