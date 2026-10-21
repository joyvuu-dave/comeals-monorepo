# typed: strict
# frozen_string_literal: true

# The attendance_version of an attendance write (POST, PATCH or DELETE
# /api/v1/meals/:meal_id/residents/:resident_id): the version of the
# person's attendance on the meal that the page expects the server to
# have before this write (AttendanceVersion; public/api.md, "The
# attendance version").
#
# Left out, or null, it is nil, and the write is not checked. A page
# loaded before the check existed sends none, and must keep working the
# way it did, until it is loaded again.
#
# Taken: a whole number, 0 or more, as a JSON number or as text of
# digits (a form-encoded body sends every value as text). Everything
# else is refused with a 400: 4.0, "4.0", "-1", "", "04".
module AttendanceVersionParam
  extend T::Sig

  REFUSAL = T.let('Attendance version must be a whole number, 0 or more.', String)

  # 18 digits at most, so the number fits the bigint column.
  DIGITS = T.let(/\A(0|[1-9][0-9]{0,17})\z/, Regexp)
  private_constant :DIGITS

  # The version, nil when none was sent, or the message of the 400.
  sig { params(params: ActionController::Parameters).returns(T.nilable(T.any(Integer, String))) }
  def self.from_params(params)
    raw = params[:attendance_version]
    return nil if raw.nil?
    return raw if raw.is_a?(Integer) && raw.to_s.match?(DIGITS)
    return Integer(raw, 10) if raw.is_a?(String) && raw.match?(DIGITS)

    REFUSAL
  end
end
