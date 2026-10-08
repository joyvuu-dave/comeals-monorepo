# frozen_string_literal: true

require 'rails_helper'

# The one rule for a true/false value in an API request (#138). The
# request specs check each endpoint that reads one; this file checks the
# rule itself, value by value.
RSpec.describe TrueOrFalse do
  describe '.read' do
    it 'reads true, 1, "true" and "1" as true' do
      [true, 1, 'true', '1'].each do |raw|
        expect(described_class.read(raw)).to be(true), raw.inspect
      end
    end

    it 'reads false, 0, "false" and "0" as false' do
      [false, 0, 'false', '0'].each do |raw|
        expect(described_class.read(raw)).to be(false), raw.inspect
      end
    end

    # Rails reads most of these as true: every value but nil, "" and its
    # own false words ("f", "off", "FALSE" and so on). Here each one is
    # refused. A Float is refused too, even 1.0: a JSON body sends 1, not
    # 1.0, for a flag.
    it 'answers nil for every other value' do
      ['', ' ', 'True', 'TRUE', 'False', 'FALSE', 't', 'f', 'on', 'off', 'yes', 'no', 'maybe',
       ' true', 'false ', '01', '1.0', nil, 2, -1, 1.0, 0.0, [], ['true'], {}, { 'a' => '1' }].each do |raw|
        expect(described_class.read(raw)).to be_nil, raw.inspect
      end
    end
  end

  describe '.refusal' do
    # The words the models use for a nil (#121): Rails writes the column's
    # name the same way in a model's error.
    it 'names the value in the words the models use' do
      expect(described_class.refusal(:late)).to eq('Late must be true or false')
      expect(described_class.refusal(:all_day)).to eq('All day must be true or false')
      expect(described_class.refusal(:no_cost)).to eq('No cost must be true or false')
    end
  end

  describe '.from_params' do
    def from(hash, names, required:)
      described_class.from_params(ActionController::Parameters.new(hash), names, required: required)
    end

    it 'answers each value by its name' do
      expect(from({ 'late' => '1', 'vegetarian' => false }, %i[late vegetarian], required: true))
        .to eq(late: true, vegetarian: false)
    end

    it 'reads only the names it is asked for' do
      expect(from({ 'late' => 'true', 'title' => 'no' }, %i[late], required: true)).to eq(late: true)
    end

    it 'refuses a required value that is left out, null or ""' do
      expect(from({}, %i[late], required: true)).to eq('Late must be true or false')
      expect(from({ 'late' => nil }, %i[late], required: true)).to eq('Late must be true or false')
      expect(from({ 'late' => '' }, %i[late], required: true)).to eq('Late must be true or false')
    end

    # A change leaves out what it does not change, so the caller keeps the
    # stored value. A value that is sent is read the same as a required one.
    it 'leaves out a value that is not required and not sent, and reads one that is sent' do
      expect(from({}, %i[late vegetarian], required: false)).to eq({})
      expect(from({ 'vegetarian' => 0 }, %i[late vegetarian], required: false)).to eq(vegetarian: false)
      expect(from({ 'late' => nil }, %i[late], required: false)).to eq('Late must be true or false')
      expect(from({ 'late' => '' }, %i[late], required: false)).to eq('Late must be true or false')
    end

    # A nested object in a request is a Parameters, not a Hash.
    it 'refuses an object or a list' do
      expect(from({ 'late' => { 'a' => '1' } }, %i[late], required: true)).to eq('Late must be true or false')
      expect(from({ 'late' => ['true'] }, %i[late], required: false)).to eq('Late must be true or false')
    end

    it 'names every refused value, one per line, in the order asked for' do
      expect(from({ 'vegetarian' => 'Off', 'late' => 'False' }, %i[late vegetarian], required: true))
        .to eq("Late must be true or false\nVegetarian must be true or false")
      expect(from({ 'late' => 'no', 'vegetarian' => true }, %i[late vegetarian], required: false))
        .to eq('Late must be true or false')
    end
  end
end
