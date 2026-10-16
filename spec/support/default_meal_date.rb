# frozen_string_literal: true

# Start the count behind the date of a meal made with no date again
# before every example (DefaultMealDate, spec/factories/meals.rb). Then
# the default dates of an example are the same on every run, whatever
# order the specs run in.
#
# Only this count starts again. The other sequences give names and
# emails that must be unique, and nothing checks those against rows that
# are already in the database the way DefaultMealDate checks dates.
RSpec.configure do |config|
  config.before { DefaultMealDate.restart }
end
