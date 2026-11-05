# typed: strict
# frozen_string_literal: true

# Before the Common House login existed, the shared screen in the Common
# House signed in with a resident's account, so the history names that
# resident for every change the screen made. relabel moves the history
# rows that account wrote before a cutoff to the Common House login, and
# the history then shows them as "Common House" (AuditSerializer).
#
# The account's id and the cutoff are inputs, not constants: they belong
# to a real person, and the repo is public. Run it with
# rake history:relabel_as_common_house.
module CommonHouseHistory
  extend T::Sig

  class Refused < StandardError; end

  # A time with its zone: Z or an offset like -07:00 at the end.
  INSTANT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)\z/

  # Moves the rows and answers how many. With write: false it only counts
  # them.
  #
  # The cutoff may not be after the login was made. Rows written after
  # that may be the resident's own, from their own phone. It also means
  # every Common House row older than the login came from this method, so
  # the change can be undone exactly: move the Common House rows older
  # than the login back to the resident.
  sig { params(resident_id: Integer, before: Time, write: T::Boolean).returns(Integer) }
  def self.relabel(resident_id:, before:, write:)
    login = CommonHouseLogin.first
    raise Refused, 'There is no Common House login yet. An admin makes it first.' if login.nil?
    raise Refused, "No resident has id #{resident_id}." unless Resident.exists?(resident_id)

    made = T.must(login.created_at).to_time
    if before > made
      raise Refused, "The cutoff must not be after the Common House login was made (#{made.getutc.iso8601})."
    end

    rows = Audited::Audit.where(user_type: 'Resident', user_id: resident_id, created_at: ...before)
    # One UPDATE, so the rows move together or not at all.
    write ? rows.update_all(user_type: 'CommonHouseLogin', user_id: login.id) : rows.count
  end

  # A date alone, or a time with no zone, could name several instants, and
  # the rows near the cutoff would move or not depending on which.
  sig { params(text: String).returns(Time) }
  def self.parse_instant(text)
    unless INSTANT.match?(text)
      raise Refused, 'BEFORE must be a time with its zone, like 2021-10-26T00:00:00-07:00. ' \
                     "It was #{text.inspect}."
    end

    Time.iso8601(text)
  end
end
