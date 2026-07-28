# frozen_string_literal: true

# Per-request attributes. Automatically reset between requests by Rails middleware.
# See https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html
class Current < ActiveSupport::CurrentAttributes
  attribute :community

  # True when this request authenticated with READ_ONLY_ADMIN_TOKEN instead of
  # a Devise session. SuperuserAdapter reads it to force the request read-only
  # and to limit which resources it may reach. It lives here because
  # ActiveAdmin builds the authorization adapter with the resource and the
  # user, never the request, so the adapter has no other way to see it.
  # ApplicationController sets it on every request. See
  # docs/adr/0004-admin-authorization.md.
  attribute :read_only_admin_token
end
