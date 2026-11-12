# frozen_string_literal: true

module Faults
  # What a fault run found (challenge 30), beyond the storm's own checks:
  #
  #   - a write whose answer was lost, sent again, where the first send
  #     worked (2xx) and the second was answered with an error: the
  #     phone shows an error for a write that was saved;
  #   - a write sent again that was saved twice: two events or two common
  #     house bookings with the title one request gave them.
  #
  # And, as counts only, what the faults were and what they did.
  module Report
    # A path with its ids taken out, so the same route counts as one.
    def self.route(method, path) = "#{method.upcase} #{path.gsub(%r{/\d+(?=/|\z)}, '/:id')}"

    # A sign-up, a take-off or a change of one person's attendance. The
    # page sends each with the attendance version it expects, and a send
    # built on an old version is answered 409 "stale", after which the
    # page loads the meal again (ADR 0012). The storm client sends no
    # version, like a page loaded before that check, so its second send
    # is answered as a new request. That is the answer ADR 0012 chose.
    ATTENDANCE = %r{\A(?:POST|PATCH|DELETE) /api/v1/meals/:id/residents/:id\z}

    # A 503 from DatabaseUnreachable is not an error for the write: it says
    # the server could not tell, and the phone sends it again.
    def self.error_for_a_saved_write(resends)
      resends.select { ok?(it.first_status) && !ok?(it.second_status) && !unreachable?(it) }
             .reject { route(it.verb, it.path).match?(ATTENDANCE) }
             .group_by { [route(it.verb, it.path), it.first_status, it.second_status] }
             .map do |(route, first, second), list|
        "#{route}: answered #{second} when sent again after #{first} (#{list.size}x): #{list.first.second_body[0, 160]}"
      end
    end

    def self.saved_twice
      twice = ->(relation) { relation.group(:title).having('count(*) > 1').count }
      twice.call(Event.where('title LIKE ?', 'storm-event-%')).map { |title, n| "event #{title} saved #{n} times" } +
        twice.call(CommonHouseReservation.where('title LIKE ?', 'storm-chr-%'))
             .map { |title, n| "common house booking #{title} saved #{n} times" }
    end

    def self.resend_tally(resends)
      resends.group_by { route(it.verb, it.path) }
             .transform_values { |list| list.map { "#{it.first_status}->#{it.second_status}" }.tally }
    end

    def self.ok?(status) = status.is_a?(Integer) && status.between?(200, 299)

    def self.unreachable?(resend)
      resend.second_status == 503 && resend.second_body.include?('could not reach its database')
    end
  end
end
