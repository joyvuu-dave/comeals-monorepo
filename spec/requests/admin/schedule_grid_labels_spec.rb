# frozen_string_literal: true

require 'rails_helper'

# The schedule grid's row labels name real calendar weeks ("Week of Aug 9
# (this week)"), never "Week 1" — a bare row number reads as "starting now",
# which the epoch-pinned cycle does not promise. Rows appear in calendar
# order (this week first) even when that differs from the stored slot order,
# and each row's fields keep their slot name. These examples pin the labels
# and the ordering on the edit form and the show page, and the data
# attributes the add/remove-week JS uses (ScheduleWeekLabelHelper).
RSpec.describe 'Admin schedule grid labels' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  def grid_rows
    response.parsed_body.css('#schedule-grid tbody tr').map do |tr|
      { label: tr.at_css('.schedule-week-label').text.strip,
        name: tr.at_css('input')['name'] }
    end
  end

  # 2026-08-07 is a Friday in the week of Sunday 2026-08-02, which is 1387
  # weeks after MealSchedule::EPOCH. With the default 2-week schedule that
  # week is slot 1, so slot order and calendar order differ.
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

  it 'shows rows in calendar order while their fields keep the slot names' do
    travel_to Date.new(2026, 8, 7) do
      get "/communities/#{community.id}/edit"
    end

    expect(grid_rows).to eq(
      [{ label: 'Week of Aug 2 (this week)', name: 'community[schedule][1][]' },
       { label: 'Week of Aug 9', name: 'community[schedule][0][]' }]
    )
  end

  # 1387 % 3 is 1, so slot order (1, 2, 0) differs from calendar order in
  # both directions.
  it 'keeps dates ascending with a three-week cycle mid-phase' do
    community.update!(schedule: [[1], [2], [3]])

    travel_to Date.new(2026, 8, 7) do
      get "/communities/#{community.id}/edit"
    end

    expect(grid_rows).to eq(
      [{ label: 'Week of Aug 2 (this week)', name: 'community[schedule][1][]' },
       { label: 'Week of Aug 9', name: 'community[schedule][2][]' },
       { label: 'Week of Aug 16', name: 'community[schedule][0][]' }]
    )
  end

  it 'labels the show page rows the same way, in calendar order' do
    travel_to Date.new(2026, 8, 7) do
      get "/communities/#{community.id}"
    end

    expect(response.body).to include('Week of Aug 2 (this week)')
    expect(response.body).to include('Week of Aug 9')
    expect(response.body).to include('This pattern repeats every 2 weeks.')
    expect(response.body.index('Week of Aug 2 (this week)'))
      .to be < response.body.index('Week of Aug 9')
  end
end
