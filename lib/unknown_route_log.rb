# typed: true
# frozen_string_literal: true

# Writes a request for a path that no route matches as one INFO line,
# not as an ERROR with a backtrace.
#
# Rails answers such a request 404. Before answering, it writes the
# exception at the level in config.action_dispatch
# .debug_exception_log_level, which is ERROR, the same as a crash. A
# scanner asks for many paths at once (117 in two seconds on 2026-10-23,
# for /.env, /.git/config and the like), so an alert on ERROR lines fired
# for every scanner. The backtrace says nothing either: Rails raises the
# exception itself, in ActionDispatch::DebugExceptions, after the router
# found no route.
#
# INFO, not WARN. A 404 for a path that is not there needs no one to do
# anything, the same as the "Completed 404" line Rails writes at INFO
# for a page that is missing. WARN would be the next level someone puts
# an alert on, and the scanners would fill it the same way.
#
# DebugExceptions calls this (an interceptor) for every exception it
# sees, before it writes the log. For a routing error it turns off the
# log of rescued exceptions for this one request, and writes its own
# line instead. Every other exception, a 500 among them, is left as it
# was: ERROR, with its backtrace. Bugsnag never saw these: its Rack
# middleware sits inside DebugExceptions, and the exception is raised
# outside it.
class UnknownRouteLog
  # Rails reads this header when it decides whether to write a rescued
  # exception, one that has a status of its own in rescue_responses (a
  # routing error is a 404). It is config.action_dispatch
  # .log_rescued_responses, read per request.
  LOG_RESCUED = 'action_dispatch.log_rescued_responses'

  def self.call(request, exception)
    return unless exception.is_a?(ActionController::RoutingError)

    request.set_header(LOG_RESCUED, false)
    # The message names the method and the path, with the path quoted by
    # Ruby's inspect, so a path cannot start a new line in the log.
    Rails.logger.info("#{exception.message} (404 Not Found)")
  end
end
