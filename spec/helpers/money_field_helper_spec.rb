# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MoneyFieldHelper do
  describe '#money_field_value' do
    it 'renders a stored amount as dollars and cents' do
      expect(helper.money_field_value(BigDecimal('16'))).to eq('16.00')
      expect(helper.money_field_value(BigDecimal('4.5'))).to eq('4.50')
    end

    it 'renders nil as blank (no cap set, or a blank submit re-render)' do
      expect(helper.money_field_value(nil)).to be_nil
    end

    it 'renders zero as blank only when asked (a new bill)' do
      expect(helper.money_field_value(BigDecimal('0'), blank_when_zero: true)).to be_nil
      expect(helper.money_field_value(BigDecimal('0'))).to eq('0.00')
    end

    # After a "must be whole cents" refusal, the field must still show the
    # typo the error names — never a rounded value that looks valid.
    it 'echoes a sub-cent value exactly instead of rounding it' do
      expect(helper.money_field_value(BigDecimal('16.005'))).to eq('16.005')
    end
  end
end
