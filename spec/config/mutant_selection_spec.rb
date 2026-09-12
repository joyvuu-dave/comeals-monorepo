# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/mutant/specs')

# The lists that tell mutant which examples prove which classes
# (spec/support/mutant/specs.rb). Two things can go quietly wrong with
# them, and both make a mutant run report survivors that mean nothing.
RSpec.describe 'the mutant spec selection' do
  def described_class_of(path)
    Rails.root.join(path).read.match(/RSpec\.describe\s+([A-Z][A-Za-z0-9:]*)\b/)&.captures&.first
  end

  it 'names only files that exist' do
    missing = (MUTANT_SPECS.keys + MUTANT_SIG_CHECK_SPECS).reject { |path| Rails.root.join(path).exist? }
    expect(missing).to be_empty
  end

  # A row replaces mutant's own selection for its file. A file that
  # describes a class would run for that class by itself; a row that
  # names other classes and forgets this one turns that off, and every
  # mutation of the class then survives with "tests: 0" — 661 of them
  # for LedgerVerification on 2026-09-12, and the MealLedger oracle
  # comparison had been silently off since the row was written.
  it 'keeps the class a file describes in that file\'s row' do
    wrong = MUTANT_SPECS.filter_map do |path, expressions|
      next if expressions.empty?

      klass = described_class_of(path)
      next if klass.nil?
      next if expressions.any? { |e| e == klass || e.start_with?("#{klass}#", "#{klass}.") }

      "#{path} describes #{klass} but its row names #{expressions.inspect}"
    end
    expect(wrong).to be_empty
  end

  # A concern's methods are tested through the models that include it,
  # and mutant only runs those examples for the concern if the row says
  # so. Without this, the concerns were mapped to a few admin request
  # specs only (2026-09-12: ReconciledMealImmutability's re-parent guard
  # could return false and survive, while bill_spec had the very example
  # that proves it).
  it 'names every concern a model includes in the rows of that model\'s specs' do
    concerns = Rails.root.glob('app/models/concerns/*.rb').map { |f| f.basename('.rb').to_s.camelize.constantize }
    wrong = Rails.root.glob('spec/models/**/*_spec.rb').filter_map do |file|
      path = file.relative_path_from(Rails.root).to_s
      next if MUTANT_SIG_CHECK_SPECS.include?(path)

      klass = described_class_of(path)&.safe_constantize
      next unless klass.is_a?(Class) && klass < ApplicationRecord

      included = (klass.included_modules & concerns).map(&:name)
      next if included.empty?

      row = MUTANT_SPECS.fetch(path, [])
      missing = included - row
      next if missing.empty?

      "#{path} describes #{klass.name}, which includes #{missing.join(', ')}, but its row is #{row.inspect}"
    end
    expect(wrong).to be_empty
  end

  it 'adds the base controller to every request spec that has a row' do
    api = MUTANT_SPECS.select { |path, expressions| path.start_with?('spec/requests/api/v1/') && expressions.any? }
    admin = MUTANT_SPECS.select { |path, expressions| path.start_with?('spec/requests/admin/') && expressions.any? }

    expect(api).not_to be_empty
    expect(api.values).to all(include('ApiController'))
    expect(admin.values).to all(include('ApplicationController'))
    expect(MUTANT_SPECS.fetch('spec/requests/api/v1/meal_random_actions_spec.rb')).to eq([])
  end

  it 'gives every runtime type-check spec an empty list, since mutant drops the sig' do
    types_specs = Rails.root.glob('spec/**/*_types_spec.rb').map { |f| f.relative_path_from(Rails.root).to_s }
    expect(MUTANT_SIG_CHECK_SPECS).to match_array(types_specs)
  end
end
