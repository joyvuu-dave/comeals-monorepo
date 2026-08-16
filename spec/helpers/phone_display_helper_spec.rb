# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PhoneDisplayHelper do
  describe '#formatted_phone' do
    it 'shows a home-country number in the local style' do
      expect(helper.formatted_phone('+15105552671')).to eq('(510) 555-2671')
    end

    it 'shows a foreign number with its country code' do
      expect(helper.formatted_phone('+442079460958')).to eq('+44 20 7946 0958')
    end

    it 'returns nil for a missing number' do
      expect(helper.formatted_phone(nil)).to be_nil
      expect(helper.formatted_phone('')).to be_nil
    end

    it 'shows a stored value the parser rejects as stored' do
      expect(helper.formatted_phone('garbage')).to eq('garbage')
    end
  end
end
