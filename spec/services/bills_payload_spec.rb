# frozen_string_literal: true

require 'rails_helper'

# The bills list as a client sends it, checked and written. The request
# specs (spec/requests/api/v1/update_bills_spec.rb) prove the endpoint;
# this pins the rules where they live, one sentence per thing that can
# be wrong, and the touched/untouched distinction that decides which
# stored values a write may replace.
RSpec.describe BillsPayload do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:other) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  def payload(rows)
    described_class.parse(rows.map { |row| row.transform_keys(&:to_s) })
  end

  describe 'the checks, in order' do
    it 'refuses anything that is not a list of rows, including the empty string a form sends' do
      expect(described_class.parse('').error).to eq('bills must be a list of cooks.')
      expect(described_class.parse(nil).error).to eq('bills must be a list of cooks.')
      expect(described_class.parse(['12.00']).error).to eq('bills must be a list of cooks.')
    end

    it 'refuses the same cook twice, by number' do
      expect(payload([{ resident_id: cook.id, amount: '1' }, { resident_id: cook.id.to_s }]).error)
        .to eq("Duplicate cook in bills: resident ##{cook.id}.")
    end

    it 'refuses an amount that is not whole cents, quoting what was sent' do
      expect(payload([{ resident_id: cook.id, amount: '1.005' }]).error)
        .to eq('Invalid amount: 1.005. Amounts are whole cents, 0 to 9999.99.')
      expect(payload([{ resident_id: cook.id, amount: '1e3' }]).error)
        .to eq('Invalid amount: 1e3. Amounts are whole cents, 0 to 9999.99.')
      expect(payload([{ resident_id: cook.id, amount: '10000' }]).error)
        .to eq('Invalid amount: 10000. Amounts are whole cents, 0 to 9999.99.')
    end

    it 'refuses a cook who is not a resident, after the amounts' do
      expect(payload([{ resident_id: 0, amount: '1.00' }]).error).to eq('Resident not found.')
    end

    it 'stops at the first problem and reports that one' do
      expect(payload([{ resident_id: 0, amount: 'ten' }]).error)
        .to eq('Invalid amount: ten. Amounts are whole cents, 0 to 9999.99.')
    end

    it 'accepts a blank amount as zero and the largest whole-cent amount' do
      expect(payload([{ resident_id: cook.id, amount: '' }, { resident_id: other.id, amount: '9999.99' }])).to be_valid
    end
  end

  describe '#write_to' do
    it 'writes touched rows, keeps untouched ones as stored, removes cooks left out' do
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('7'), no_cost: false)
      create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('3'), no_cost: false)
      gone = create(:resident, community: community, unit: unit)
      create(:bill, meal: meal, resident: gone, community: community, amount: BigDecimal('1'), no_cost: false)

      payload([{ resident_id: cook.id, amount: '12.50', no_cost: false }, { resident_id: other.id }]).write_to(meal)

      rows = meal.bills.reload.to_h { |b| [b.resident_id, [b.amount, b.no_cost]] }
      expect(rows).to eq(cook.id => [BigDecimal('12.5'), false], other.id => [BigDecimal('3'), false])
    end

    it 'creates a bill with the column defaults for a new cook sent without values' do
      payload([{ resident_id: cook.id }]).write_to(meal)

      bill = meal.bills.find_by(resident_id: cook.id)
      expect([bill.amount, bill.no_cost]).to eq([BigDecimal('0'), false])
    end

    it 'writes a no_cost row with a zero amount' do
      payload([{ resident_id: cook.id, amount: '0', no_cost: true }]).write_to(meal)

      expect(meal.bills.find_by(resident_id: cook.id).no_cost).to be(true)
    end
  end
end
