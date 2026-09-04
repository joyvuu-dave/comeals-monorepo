# typed: false
# frozen_string_literal: true

# A phone column that accepts any way of typing a number and stores one
# canonical form.
#
# People type numbers many ways: "(510) 555-2671", "510.555.2671",
# "+44 20 7946 0958". All of those are accepted. Before validation, the
# input is parsed with Phonelib (the Ruby port of Google's libphonenumber,
# which knows every country's numbering plan). A valid number is replaced
# with its E.164 form — "+", country code, digits, nothing else — so the
# database holds exactly one form, and it is the form every SMS service
# takes as input. Input without a + prefix is read as a number from
# Phonelib.default_country (see config/initializers/phonelib.rb).
#
# "Valid" means the number matches a real allocated range in its country,
# not just a plausible digit count. Invalid input is kept as typed so the
# person can see and fix what they entered, and validation rejects it.
#
# A CHECK constraint on each phone column backstops the E.164 shape for
# writes that skip the model.
module HasPhoneNumber
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_phone
    validate :phone_must_be_a_real_number
  end

  private

  def normalize_phone
    if phone.blank?
      self.phone = nil
      return
    end

    parsed = Phonelib.parse(phone)
    self.phone = parsed.e164 if parsed.valid?
  end

  def phone_must_be_a_real_number
    return if phone.nil? || Phonelib.valid?(phone)

    errors.add(:phone, 'does not look like a real phone number. Enter it with the area code ' \
                       '(510-555-2671). For a number outside the US, start with + and the ' \
                       'country code (+44 20 7946 0958).')
  end
end
