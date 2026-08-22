# frozen_string_literal: true

require 'rails_helper'

# Every color the calendar puts behind chip text must pass WCAG AA
# (4.5:1) with the text color the client picks for it, in BOTH states
# the calendar renders: as-is for upcoming events, and dimmed with a
# CSS saturate(35%) filter for past ones. The client picks black or
# white text by background luminance (eventTextColor in
# calendar/show.jsx); this spec reimplements that math so a color
# change that breaks the rule fails here instead of in a Lighthouse
# run months later. Rotation red has already been through this twice —
# see the comment on Rotation::COLORS.
RSpec.describe 'Calendar chip contrast', type: :serializer do
  def channel_to_linear(value)
    v = value / 255.0
    v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4
  end

  def wcag_luminance(rgb)
    r, g, b = rgb.map { |c| channel_to_linear(c) }
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  def contrast(lum_a, lum_b)
    hi, lo = [lum_a, lum_b].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  # CSS filter: saturate(s). The filter-effects spec defines the CSS
  # shorthand functions on gamma-encoded sRGB values.
  def saturate(rgb, amount)
    r, g, b = rgb
    s = amount
    [
      ((0.213 + (0.787 * s)) * r) + ((0.715 - (0.715 * s)) * g) + ((0.072 - (0.072 * s)) * b),
      ((0.213 - (0.213 * s)) * r) + ((0.715 + (0.285 * s)) * g) + ((0.072 - (0.072 * s)) * b),
      ((0.213 - (0.213 * s)) * r) + ((0.715 - (0.715 * s)) * g) + ((0.072 + (0.928 * s)) * b)
    ].map { |v| v.clamp(0, 255) }
  end

  def hex_to_rgb(hex)
    h = hex.delete('#')
    h = h.chars.map { |c| c * 2 }.join if h.length == 3
    h.scan(/../).map { |pair| pair.to_i(16) }
  end

  def expect_chip_to_pass(hex, label)
    rgb = hex_to_rgb(hex)
    base = wcag_luminance(rgb)
    # 0.179 is eventTextColor's black/white tipping point.
    text = base > 0.179 ? 0.0 : 1.0
    dimmed = wcag_luminance(saturate(rgb, 0.35))

    expect(contrast(text, base)).to be >= 4.5, "#{label} #{hex} fails as-is"
    expect(contrast(text, dimmed)).to be >= 4.5, "#{label} #{hex} fails dimmed to 35% saturation"
  end

  it 'every rotation color passes with its chosen text, as-is and dimmed' do
    Rotation::COLORS.each { |hex| expect_chip_to_pass(hex, 'rotation color') }
  end

  it 'every serializer chip color passes with its chosen text, as-is and dimmed' do
    # Each of these serializers keeps its color in a constant, so it can
    # be read without a real record. If one ever computes color from its
    # record, build the record here and read the attribute instead.
    {
      EventSerializer => 'event',
      GuestRoomReservationSerializer => 'guest room',
      CommonHouseReservationSerializer => 'common house',
      ResidentBirthdaySerializer => 'birthday',
      MealSerializer => 'meal'
    }.each do |serializer, label|
      expect_chip_to_pass(serializer::CHIP_COLOR, label)
    end
  end
end
