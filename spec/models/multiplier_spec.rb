# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Multiplier do
  it 'defines the three price bands' do
    expect(Multiplier::FREE).to eq(0)
    expect(Multiplier::HALF).to eq(1)
    expect(Multiplier::FULL).to eq(2)
  end

  # A guest pays as an adult or as a child. Free is a price only a
  # resident's age gives. Adult comes first: the admin meal form lists
  # the prices in this order, and a new guest is an adult.
  it 'gives a guest the adult price or the child price, adult first' do
    expect(Multiplier::GUEST_PRICES).to eq([Multiplier::FULL, Multiplier::HALF])
  end

  # The one rendering of a price. Every admin page that names one calls
  # it (through ApplicationHelper#price_category_label), and so does the
  # meal history (AuditDescription). Five hand-written copies once
  # disagreed (#51).
  describe '.label' do
    it 'names an adult and a child' do
      expect([Multiplier::FULL, Multiplier::HALF].map { |value| described_class.label(value) })
        .to eq(%w[Adult Child])
    end

    # The community form's words for the age rule: "Children under 5 eat free."
    it 'names a child who eats free as free, not as a multiple of an adult' do
      expect(described_class.label(Multiplier::FREE)).to eq('Child (free)')
    end

    it 'names any other value as a multiple of an adult' do
      expect([3, 4, 5].map { |value| described_class.label(value) }).to eq(['Adult x 1.5', 'Adult x 2', 'Adult x 2.5'])
    end
  end

  # A schema default cannot reference a Ruby constant, so the database
  # writes it as the literal 2. This is what keeps it from drifting away
  # from Multiplier::FULL. (residents.multiplier is an ignored column
  # since 2026-09-26; a resident's band is computed from the birthday.)
  describe 'database column defaults' do
    it 'pins guests.multiplier to FULL' do
      expect(Guest.column_defaults.fetch('multiplier')).to eq(Multiplier::FULL)
    end
  end

  # The ledger's ignorance of what a multiplier means is the design: it
  # sums multipliers into a divisor and never asks what a value of 2 means.
  # Pricing policy must not leak into it (see the module comment).
  it 'is not referenced by MealLedger' do
    source = Rails.root.join('app/services/meal_ledger.rb').read
    code_lines = source.lines.reject { |line| line.strip.start_with?('#') }
    expect(code_lines.join).not_to match(/\bMultiplier\b/)
  end
end
