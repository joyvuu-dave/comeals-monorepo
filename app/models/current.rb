# typed: true
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

  # The community's resident names, read once per request by
  # ResidentNameShortener — a serializer collection shortens one name
  # per row, and each row must not re-run the pluck.
  attribute :resident_names

  # The Pusher socket id of the browser making this request, from the
  # socket_id param. LiveUpdate excludes it from the meal-page push, so a
  # tap never tells its own screen to refetch. Nil outside the API.
  attribute :socket_id

  # LiveUpdate's pending batches: one per open database transaction,
  # keyed by the transaction's uuid, and the manual batch opened by
  # LiveUpdate.batch. See app/services/live_update.rb.
  attribute :live_update_batches
  attribute :live_update_manual_batch
end
