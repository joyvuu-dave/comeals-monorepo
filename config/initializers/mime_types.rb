# typed: false
# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Add new mime types for use in respond_to blocks:
# Mime::Type.register "text/richtext", :rtf

# public/api.md is served by the static file server. Rack does not know
# the .md extension, so without this line the file would be sent as
# application/octet-stream and a browser would download it.
Rack::Mime::MIME_TYPES['.md'] = 'text/markdown'
