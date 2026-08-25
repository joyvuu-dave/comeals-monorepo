# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduleWeekLabelHelper do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }

  # 2026-08-07 is a Friday in the week of Sunday 2026-08-02, which is 1387
  # weeks after MealSchedule::EPOCH — an odd count, so with a 2-week cycle
  # this week is slot 1.
  describe '#schedule_week_rows' do
    it 'returns rows in calendar order, each carrying its schedule slot' do
      travel_to Date.new(2026, 8, 7) do
        expect(helper.schedule_week_rows(community, 2))
          .to eq([{ slot: 1, label: 'Week of Aug 2 (this week)' },
                  { slot: 0, label: 'Week of Aug 9' }])
      end
    end

    # 1387 % 3 is 1, so slot order (1, 2, 0) differs from calendar order in
    # both directions — this pins that the dates ascend anyway.
    it 'keeps dates ascending when the current week is mid-cycle' do
      travel_to Date.new(2026, 8, 7) do
        expect(helper.schedule_week_rows(community, 3))
          .to eq([{ slot: 1, label: 'Week of Aug 2 (this week)' },
                  { slot: 2, label: 'Week of Aug 9' },
                  { slot: 0, label: 'Week of Aug 16' }])
      end
    end

    # Only reachable through forged params (an empty schedule fails
    # validation), but the form re-render must show the errors, not divide
    # by zero.
    it 'returns no rows for a zero-length schedule' do
      expect(helper.schedule_week_rows(community, 0)).to eq([])
    end
  end

  describe '#schedule_grid_data' do
    it 'ships finished labels and notes so the JS never composes wording' do
      travel_to Date.new(2026, 8, 7) do
        data = helper.schedule_grid_data(community)

        expect(data['data-epoch-weeks']).to eq(1387)
        expect(JSON.parse(data['data-week-labels']).first).to eq('Week of Aug 2 (this week)')
        expect(JSON.parse(data['data-week-labels']).second).to eq('Week of Aug 9')
        expect(JSON.parse(data['data-repeat-notes']))
          .to start_with('This pattern repeats every week.',
                         'This pattern repeats every 2 weeks.')
      end
    end
  end
end
