# typed: true
# frozen_string_literal: true

# Which request paths are scanners looking for secret files. Rack::Attack
# refuses each one with a 403 (config/initializers/rack_attack.rb).
#
# Scanners ask for files that would hold passwords or keys if a site left
# them in its web folder: /.env, /.git/config, /.aws/credentials,
# /.claude/settings.json, and the PHP and WordPress pages that old sites
# have. This app has none of them, and no page of it links to one, so
# a person using it never asks for one.
#
# A path is a probe when:
# - one of its parts starts with a dot (/.env, /app/.git/HEAD, /../x),
#   except for the first part being /.well-known/ or /.vite/;
# - one of its parts ends in .php, in any case (/login.php, /x.PHP/y);
# - one of its parts is a WordPress folder or login page (/wp-admin).
#
# The two dot folders that are allowed:
# - /.vite/ holds /.vite/manifest.json, which the version banner reads
#   to notice a deploy (version_banner.jsx). The static file server
#   answers it before Rack::Attack runs, but the rule does not count on
#   that order.
# - /.well-known/ is where browsers and password managers look for
#   files on any site (/.well-known/change-password, and Chrome's
#   DevTools asks for /.well-known/appspecific/com.chrome.devtools.json).
#   The app has none of these files, but a person's browser asks anyway.
# Only the first part may be one of these; a dot part after it still
# counts (/.vite/../.env).
#
# Nothing the app serves has such a part: the routes in config/routes.rb,
# the SPA's routes (app/frontend/src/routes.js), the files in public/,
# and the tokens in reset links (SecureRandom.urlsafe_base64, which has
# no dot) and in calendar feed links.
module SecretFileProbe
  ALLOWED_FIRST_FOLDER = %r{\A/\.(?:well-known|vite)(?=/|\z)}
  DOT_PART = %r{(?:\A|/)\.}
  PHP_PART = %r{\.php(?:/|\z)}i
  WORDPRESS_PART = %r{(?:\A|/)wp-(?:admin|content|includes|login\.php)(?:/|\z)}

  def self.match?(path)
    rest = path.sub(ALLOWED_FIRST_FOLDER, '')
    [DOT_PART, PHP_PART, WORDPRESS_PART].any? { |pattern| rest.match?(pattern) }
  end
end
