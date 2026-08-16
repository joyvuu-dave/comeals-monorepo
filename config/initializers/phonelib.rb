# frozen_string_literal: true

# A phone number typed without a + prefix is parsed as a number from this
# country. A number typed with + carries its own country code, so this
# default only decides how plain local input like "510-555-2671" is read.
# If a community outside the US ever runs this app, the fix is a country
# column on Community, passed to Phonelib.parse — not a change here.
Phonelib.default_country = 'US'
