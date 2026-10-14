# frozen_string_literal: true

require 'rails_helper'

# The words on the admin settlement preview's "Mark these blank costs as
# No cost" button and its answer (ADR 0011 rule 4).
RSpec.describe SettlementPreviewHelper do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:meal) { create(:meal, community: community, date: Date.new(2026, 3, 5)) }

  def cost(amount, no_cost: false, name: 'A Cook')
    create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit, name: name),
                  community: community, amount: BigDecimal(amount.to_s), no_cost: no_cost)
  end

  describe '#blank_cost_button_label' do
    it 'says "this" for one cost and the number for more' do
      expect([1, 2, 7].map { |count| helper.blank_cost_button_label(count) })
        .to eq(['Mark this blank cost as No cost', 'Mark these 2 blank costs as No cost',
                'Mark these 7 blank costs as No cost'])
    end
  end

  describe '#free_dinner_note' do
    it 'notes a dinner with no money on any cost, blank or No cost' do
      cost(0)
      cost(0, no_cost: true, name: 'B Cook')

      expect(helper.free_dinner_note(meal))
        .to eq('No cook on this dinner has entered an amount. After this, it is free for everyone who ate.')
    end

    it 'says nothing when a cook entered money' do
      cost(0)
      cost(5, name: 'B Cook')

      expect(helper.free_dinner_note(meal)).to be_nil
    end
  end

  describe '#no_cost_marking_words' do
    def result(marked: [], left_alone: [], gone: 0)
      NoCostMarking::Result.new(marked: marked, left_alone: left_alone, gone: gone)
    end

    it 'says how many it marked, which it left alone and why, and how many were deleted' do
      left = NoCostMarking::LeftAlone.new(bill: cost(12, name: 'B Cook'), reason: 'the cook entered a cost')

      expect(helper.no_cost_marking_words(result(marked: [cost(0)], left_alone: [left], gone: 1)))
        .to eq('Marked 1 cost as No cost. Left alone: 2026-03-05, B Cook, because the cook entered a cost. ' \
               '1 cost on the list was deleted after the list was shown.')
    end

    it 'counts more than one in the plural' do
      expect(helper.no_cost_marking_words(result(marked: [cost(0), cost(0, name: 'B Cook')], gone: 2)))
        .to eq('Marked 2 costs as No cost. 2 costs on the list were deleted after the list was shown.')
    end

    it 'says it marked none when every cost changed' do
      expect(helper.no_cost_marking_words(result)).to eq('Marked 0 costs as No cost.')
    end
  end
end
