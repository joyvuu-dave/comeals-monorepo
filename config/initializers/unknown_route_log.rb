# typed: false
# frozen_string_literal: true

require Rails.root.join('lib/unknown_route_log')

# One INFO line, not an ERROR with a backtrace, for a path no route
# matches. The reasons are in lib/unknown_route_log.rb.
ActionDispatch::DebugExceptions.register_interceptor(UnknownRouteLog)
