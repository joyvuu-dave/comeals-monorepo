# frozen_string_literal: true

# Phone numbers are stored in E.164 form ("+15105552671" — see
# HasPhoneNumber). That form is for machines. On screen, show the form
# people expect: local style for a number from the home country
# ("(510) 555-2671"), international style with the country code for
# anything else ("+44 20 7946 0958").
module PhoneDisplayHelper
  def formatted_phone(phone)
    return if phone.blank?

    parsed = Phonelib.parse(phone)
    # A stored value the parser rejects should not exist (model validation
    # and a CHECK constraint both guard the column) — but if one appears,
    # show it as stored rather than nothing.
    return phone unless parsed.valid?

    parsed.country == Phonelib.default_country ? parsed.national : parsed.international
  end
end
