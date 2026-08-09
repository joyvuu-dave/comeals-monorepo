# frozen_string_literal: true

require 'rails_helper'

# The schedule grid's row labels name real calendar weeks ("Week of Aug 9
# (this week)"), never "Week 1" — a bare row number reads as "starting now",
# which the epoch-pinned cycle does not promise. These examples pin the
# labels on the edit form and the show page, and the data attributes the
# add/remove-week JS uses to recompute them (ScheduleWeekLabelHelper).
RSpec.describe 'Admin schedule grid labels' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  # 2026-08-07 is a Friday in the week of Sunday 2026-08-02, which is 1387
  # weeks after MealSchedule::EPOCH. With the default 2-week schedule that
  # week is the second row (1387 is odd), so the first row is next week.
  it 'labels the edit form rows with the calendar weeks they map to' do
    travel_to Date.new(2026, 8, 7) do
      get "/communities/#{community.id}/edit"
    end

    expect(response.body).to include('Week of Aug 2 (this week)')
    expect(response.body).to include('Week of Aug 9')
    expect(response.body).not_to include('Week 1')
    expect(response.body).to include('This pattern repeats every 2 weeks.')
    expect(response.body).to include('data-epoch-weeks="1387"')
    expect(response.body).to include('Aug 16') # in data-week-labels for the JS
  end

  it 'labels the show page rows the same way' do
    travel_to Date.new(2026, 8, 7) do
      get "/communities/#{community.id}"
    end

    expect(response.body).to include('Week of Aug 2 (this week)')
    expect(response.body).to include('Week of Aug 9')
    expect(response.body).to include('This pattern repeats every 2 weeks.')
  end
end
