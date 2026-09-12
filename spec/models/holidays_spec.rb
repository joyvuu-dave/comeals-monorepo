# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Holidays do
  describe '.holiday?' do
    it 'detects Thanksgiving (4th Thursday in November)' do
      expect(described_class.holiday?(Date.new(2026, 11, 26))).to be true
      expect(described_class.holiday?(Date.new(2025, 11, 27))).to be true
    end

    it 'does not take the third Thursday, or a Wednesday in the fourth week, for Thanksgiving' do
      expect(described_class.holiday?(Date.new(2026, 11, 19))).to be false
      expect(described_class.holiday?(Date.new(2026, 11, 25))).to be false
    end

    it 'detects Christmas' do
      expect(described_class.holiday?(Date.new(2026, 12, 25))).to be true
    end

    it 'detects New Year' do
      expect(described_class.holiday?(Date.new(2026, 1, 1))).to be true
    end

    it 'detects Mother\'s Day (2nd Sunday in May)' do
      expect(described_class.holiday?(Date.new(2026, 5, 10))).to be true
      expect(described_class.holiday?(Date.new(2025, 5, 11))).to be true
    end

    it 'does not take the first Sunday, or a Monday in the second week, for Mother\'s Day' do
      expect(described_class.holiday?(Date.new(2026, 5, 3))).to be false
      expect(described_class.holiday?(Date.new(2026, 5, 11))).to be false
    end

    it 'detects Easter' do
      # Easter 2026 is April 5
      expect(described_class.holiday?(Date.new(2026, 4, 5))).to be true
      # Easter 2025 is April 20
      expect(described_class.holiday?(Date.new(2025, 4, 20))).to be true
      # A March Easter: 2024 was March 31
      expect(described_class.holiday?(Date.new(2024, 3, 31))).to be true
    end

    it 'detects July 4th' do
      expect(described_class.holiday?(Date.new(2026, 7, 4))).to be true
    end

    it 'returns false for non-holidays' do
      expect(described_class.holiday?(Date.new(2026, 3, 15))).to be false
      expect(described_class.holiday?(Date.new(2026, 8, 20))).to be false
    end

    # Every day of forty-one years against a list written without the
    # code: Easter Sundays as published by the US Naval Observatory, the
    # other holidays from their calendar rules. Three Easters proved the
    # method once; the arithmetic in easter? has twenty steps, and a
    # wrong constant in most of them still lands on the right Sunday in
    # three chosen years.
    def easter_sundays
      {
        2000 => [4, 23], 2001 => [4, 15], 2002 => [3, 31], 2003 => [4, 20], 2004 => [4, 11],
        2005 => [3, 27], 2006 => [4, 16], 2007 => [4, 8], 2008 => [3, 23], 2009 => [4, 12],
        2010 => [4, 4], 2011 => [4, 24], 2012 => [4, 8], 2013 => [3, 31], 2014 => [4, 20],
        2015 => [4, 5], 2016 => [3, 27], 2017 => [4, 16], 2018 => [4, 1], 2019 => [4, 21],
        2020 => [4, 12], 2021 => [4, 4], 2022 => [4, 17], 2023 => [4, 9], 2024 => [3, 31],
        2025 => [4, 20], 2026 => [4, 5], 2027 => [3, 28], 2028 => [4, 16], 2029 => [4, 1],
        2030 => [4, 21], 2031 => [4, 13], 2032 => [3, 28], 2033 => [4, 17], 2034 => [4, 9],
        2035 => [3, 25], 2036 => [4, 13], 2037 => [4, 5], 2038 => [4, 25], 2039 => [4, 10],
        2040 => [4, 1]
      }
    end

    def nth_weekday_of(year, month, wday, nth)
      first = Date.new(year, month, 1)
      first + ((wday - first.wday) % 7) + ((nth - 1) * 7)
    end

    def expected_holidays(year)
      [
        Date.new(year, 1, 1),
        Date.new(year, 7, 4),
        Date.new(year, 12, 25),
        Date.new(year, *easter_sundays.fetch(year)),
        nth_weekday_of(year, 5, 0, 2),
        nth_weekday_of(year, 11, 4, 4)
      ]
    end

    it 'marks exactly the six holidays of every year from 2000 to 2040' do
      easter_sundays.each_key do |year|
        days = (Date.new(year, 1, 1)..Date.new(year, 12, 31)).to_a
        marked = days.select { |day| described_class.holiday?(day) }

        expect(marked).to eq(expected_holidays(year).sort), "year #{year}"
      end
    end

    # Gauss's Easter algorithm, a different computation from the one in
    # the module (Meeus, Jones and Butcher). Forty-one years all share
    # one century, so a wrong constant in the century terms of the module
    # still gives the right Sunday for every one of them; nine centuries
    # do not.
    def gauss_easter(year)
      a = year % 19
      b = year % 4
      c = year % 7
      k = year / 100
      p = (13 + (8 * k)) / 25
      q = k / 4
      m = (15 - p + k - q) % 30
      n = (4 + k - q) % 7
      d = ((19 * a) + m) % 30
      e = ((2 * b) + (4 * c) + (6 * d) + n) % 7
      return Date.new(year, 4, 19) if d == 29 && e == 6
      return Date.new(year, 4, 18) if d == 28 && e == 6 && ((11 * m) + 11) % 30 < 19

      Date.new(year, 3, 22) + d + e
    end

    it 'agrees with Gauss on Easter for every year from 1583 to 2499, and marks no other day of spring' do
      (1583..2499).each do |year|
        spring = (Date.new(year, 3, 1)..Date.new(year, 4, 30)).select { |day| described_class.easter?(day) }

        expect(spring).to eq([gauss_easter(year)]), "year #{year}"
      end
    end
  end
end
