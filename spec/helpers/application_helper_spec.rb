# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#price_category_label' do
    it 'returns "Child" for multiplier 1' do
      expect(helper.price_category_label(1)).to eq('Child')
    end

    it 'returns "Adult" for multiplier 2' do
      expect(helper.price_category_label(2)).to eq('Adult')
    end

    it 'returns fractional adult for other multipliers' do
      expect(helper.price_category_label(3)).to eq('Adult x 1.5')
    end
  end
end
