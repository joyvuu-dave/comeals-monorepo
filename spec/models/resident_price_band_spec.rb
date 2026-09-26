# frozen_string_literal: true

require 'rails_helper'

# A resident's price band is computed from the birthday and the
# community's two ages, for a date. Two things have to agree: the Ruby
# rule (Resident#age_on, #multiplier_on) and the SQL rule the hosts list
# uses (Resident.adult_on). The day that can split them is February 29.
RSpec.describe Resident do
  let(:community) { create(:community, free_below_age: 5, full_price_age: 12) }
  let(:unit) { create(:unit, community: community) }

  def resident_born(date)
    create(:resident, community: community, unit: unit, birthday: date)
  end

  describe '#multiplier_on' do
    it 'is free under the first age, half price under the second, full from it' do
      today = community.today
      expect(resident_born(today - 4.years).multiplier_on(today)).to eq(Multiplier::FREE)
      expect(resident_born(today - 5.years).multiplier_on(today)).to eq(Multiplier::HALF)
      expect(resident_born(today - 11.years - 364.days).multiplier_on(today)).to eq(Multiplier::HALF)
      expect(resident_born(today - 12.years).multiplier_on(today)).to eq(Multiplier::FULL)
    end

    it 'is full price with no birthday' do
      expect(create(:resident, community: community, unit: unit, birthday: nil).multiplier_on(community.today))
        .to eq(Multiplier::FULL)
    end

    it 'changes on the day itself: a child the day before the twelfth birthday, an adult on it' do
      born = Date.new(2014, 6, 15)
      resident = resident_born(born)

      expect(resident.multiplier_on(Date.new(2026, 6, 14))).to eq(Multiplier::HALF)
      expect(resident.multiplier_on(Date.new(2026, 6, 15))).to eq(Multiplier::FULL)
    end

    it 'follows the community ages, and both zero means everyone with a birthday pays full price' do
      community.update!(free_below_age: 0, full_price_age: 0)

      expect(resident_born(community.today - 2.years).multiplier_on(community.today)).to eq(Multiplier::FULL)
    end
  end

  describe '#age_on' do
    it 'counts a February 29 birthday on March 1 in a year with no February 29' do
      resident = resident_born(Date.new(2020, 2, 29))

      expect(resident.age_on(Date.new(2027, 2, 28))).to eq(6)
      expect(resident.age_on(Date.new(2027, 3, 1))).to eq(7)
      expect(resident.age_on(Date.new(2028, 2, 28))).to eq(7)
      expect(resident.age_on(Date.new(2028, 2, 29))).to eq(8)
    end
  end

  describe '.adult_on' do
    it 'agrees with the Ruby rule on every day of a leap year and a non-leap year, for a February 29 birthday' do
      community.update!(free_below_age: 3, full_price_age: 7)
      resident = resident_born(Date.new(2020, 2, 29))

      disagreements = (Date.new(2027, 1, 1)..Date.new(2028, 12, 31)).reject do |date|
        in_sql = described_class.adult_on(date, community: community).exists?(resident.id)
        in_ruby = resident.multiplier_on(date) == Multiplier::FULL
        in_sql == in_ruby
      end

      expect(disagreements).to be_empty
      expect(described_class.adult_on(Date.new(2027, 2, 28), community: community).exists?(resident.id)).to be(false)
      expect(described_class.adult_on(Date.new(2027, 3, 1), community: community).exists?(resident.id)).to be(true)
    end

    it 'includes a resident with no birthday' do
      adult = create(:resident, community: community, unit: unit, birthday: nil)

      expect(described_class.adult_on(community.today, community: community)).to include(adult)
    end

    it 'is what .adult means today' do
      child = resident_born(community.today - 8.years)
      adult = resident_born(community.today - 12.years)

      expect(described_class.adult).to include(adult)
      expect(described_class.adult).not_to include(child)
    end
  end

  describe '#child?' do
    it 'is true under the full-price age today and false from it, or with no birthday' do
      expect(resident_born(community.today - 8.years)).to be_child
      expect(resident_born(community.today - 12.years)).not_to be_child
      expect(create(:resident, community: community, unit: unit, birthday: nil)).not_to be_child
    end
  end
end
