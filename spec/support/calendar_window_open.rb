# frozen_string_literal: true

# Tag a group or an example `:calendar_window_open` to take every day as
# inside CalendarWindow.
#
# For the specs of the database's own limits (StorableTime): the first
# and last days PostgreSQL can store, in 4714 BC and 294276 AD, and the
# old time zone rules of the 1800s. The window refuses all of those
# first, so without this the specs would test the window, not the
# limits. The limits still need their specs: the window rule skips a day
# the database cannot store and leaves it to them (CalendarWindowValidator).
RSpec.shared_context 'with the calendar window open' do
  before { allow(CalendarWindow).to receive(:cover?).and_return(true) }
end

RSpec.configure do |config|
  config.include_context 'with the calendar window open', :calendar_window_open
end
