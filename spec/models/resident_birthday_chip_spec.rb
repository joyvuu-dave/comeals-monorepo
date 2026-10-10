# frozen_string_literal: true

require 'rails_helper'

# Who gets a birthday chip on the days a calendar shows. The chip goes on
# the birthday in the year the days give its month
# (ResidentBirthdaySerializer), so a person has one only from their first
# birthday on. A birthday is a year since the day of birth: the day of
# birth itself has no chip, and nor does any day before it.
RSpec.describe Resident do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  # Every resident here is made on this day, because a birthday after
  # today is refused (Resident#birthday_not_in_the_future).
  before { travel_to(Time.zone.local(2028, 3, 20, 12, 0)) }

  def born(birthday)
    create(:resident, community: community, unit: unit, birthday: birthday)
  end

  def chips_on(first_day, last_day)
    described_class.with_birthday_chip_on(first_day..last_day).order(:id).to_a
  end

  describe '.with_birthday_chip_on' do
    it 'takes the first birthday, and leaves out the day of birth and the year before it' do
      baby = born(Date.new(2026, 4, 20))
      april = ->(year) { chips_on(Date.new(year, 3, 29), Date.new(year, 5, 9)) }

      expect(april.call(2025)).to eq([])
      expect(april.call(2026)).to eq([])
      expect(april.call(2027)).to eq([baby])
    end

    # The year starts on January 1, so a baby born that day is the one
    # case where the day of birth and the first day of the year are the
    # same day.
    it 'leaves out a baby born on January 1 until the next January' do
      baby = born(Date.new(2026, 1, 1))
      january = ->(year) { chips_on(Date.new(year, 1, 1), Date.new(year, 1, 31)) }

      expect(january.call(2026)).to eq([])
      expect(january.call(2027)).to eq([baby])
    end

    it 'takes only the months on screen, with no birthday or another month left out' do
      april = born(Date.new(2000, 4, 2))
      may = born(Date.new(2000, 5, 3))
      born(Date.new(2000, 6, 1))
      born(nil)

      expect(chips_on(Date.new(2026, 4, 1), Date.new(2026, 4, 30))).to eq([april])
      expect(chips_on(Date.new(2026, 3, 29), Date.new(2026, 5, 9))).to eq([april, may])
    end

    # The December 2026 grid runs from November 29, 2026 to January 9,
    # 2027. Its November and December days are in 2026 and its January
    # days in 2027, so each month is read in its own year.
    it 'reads each month in its own year on a grid that crosses New Year' do
      december_first = born(Date.new(2025, 12, 2))
      born(Date.new(2026, 12, 2))
      january_first = born(Date.new(2026, 1, 5))
      born(Date.new(2027, 1, 5))

      expect(chips_on(Date.new(2026, 11, 29), Date.new(2027, 1, 9))).to eq([december_first, january_first])
    end

    # No days on screen, no chips. The conditions are joined with OR, and
    # an empty list of them was an empty WHERE, which took everyone.
    it 'takes nobody for no days' do
      born(Date.new(2000, 4, 2))
      born(nil)

      expect(described_class.with_birthday_chip_on([]).to_a).to eq([])
    end

    # A February 29 birthday is drawn on February 28 in a year with no
    # February 29, so the first birthday of a leap-day baby is on
    # February 28 of the next year.
    it 'takes the first birthday of someone born on February 29' do
      leapling = born(Date.new(2024, 2, 29))
      february = ->(year) { chips_on(Date.new(year, 2, 1), Date.new(year, 3, 14)) }

      expect(february.call(2024)).to eq([])
      expect(february.call(2025)).to eq([leapling])
      expect(february.call(2028)).to eq([leapling])
    end
  end
end
