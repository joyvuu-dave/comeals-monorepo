# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261013120200_fix_a_cost_typed_with_an_extra_zero.rb')

# The data migration that changes one cook's cost on one dinner from the
# cost typed with an extra zero to the cost the cook spent.
RSpec.describe FixACostTypedWithAnExtraZero do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:dinner) { create(:meal, community: community, date: described_class::DINNER) }
  let!(:typed) { create(:bill, meal: dinner, resident: person('Tia Typed'), community: community, amount: 170) }
  let!(:other) { create(:bill, meal: dinner, resident: person('Ann Other'), community: community, amount: 27.42) }

  before { create(:meal_resident, meal: dinner, resident: person('Eli Eater'), community: community) }

  def person(name)
    create(:resident, community: community, unit: unit, name: name)
  end

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def fix_rows
    Audited::Audit.where(auditable_type: 'Bill', comment: described_class::COMMENT)
  end

  describe 'up' do
    it 'changes the cost typed ten times too high to the cost spent, and no other cost' do
      migrate(:up)

      expect(typed.reload).to have_attributes(amount: 17, no_cost: false)
      expect(other.reload.amount).to eq(BigDecimal('27.42'))
    end

    it 'writes the audit row a save would write, by no person, and the meal history says Automatic fix' do
      migrate(:up)

      expect(fix_rows.sole).to have_attributes(auditable_id: typed.id, associated_id: dinner.id, action: 'update',
                                               audited_changes: { 'amount' => ['170.0', '17.0'] },
                                               version: 2, user_id: nil, username: nil)
      expect(AuditSerializer.new(dinner.reload.total_audits).to_h.first).to include(user_name: 'Automatic fix')
    end

    it 'prints what it changed, for the release log' do
      expect(migrate(:up)).to include('Changed the $170.00 cost on 2024-11-14 to $17.00.')
    end

    it 'does nothing, and says so, when the cook changed it to the right cost already' do
      typed.update!(amount: 17)

      expect(migrate(:up)).to include('The cost on 2024-11-14 is $17.00 already')
      expect(fix_rows).to be_empty
    end

    it 'does nothing on a database with no meal that day' do
      Bill.where(meal: dinner).delete_all
      MealResident.where(meal: dinner).delete_all
      dinner.delete

      expect(migrate(:up)).to include('No meal on 2024-11-14')
    end

    # Money: a state it does not expect stops the deploy and changes
    # nothing, so a person looks before any number moves.
    it 'refuses and changes nothing when the cost is some other amount' do
      typed.update!(amount: 180)

      expect { migrate(:up) }.to raise_error(RuntimeError, /0 cost\(s\) of \$170.00, not 1. Nothing was changed/)
      expect(typed.reload.amount).to eq(180)
    end

    it 'refuses and changes nothing when the dinner is settled' do
      settle!(cutoff: described_class::DINNER + 1)

      expect { migrate(:up) }.to raise_error(RuntimeError, /the dinner is settled/)
      expect(typed.reload.amount).to eq(170)
    end
  end

  describe 'down' do
    it 'puts the typed cost back and removes its row' do
      migrate(:up)

      migrate(:down)

      expect(typed.reload.amount).to eq(170)
      expect(fix_rows).to be_empty
    end

    it 'refuses when the cost changed again since' do
      migrate(:up)
      typed.reload.update!(amount: 18)

      expect { migrate(:down) }.to raise_error(RuntimeError, /changed after the fix/)
      expect(typed.reload.amount).to eq(18)
    end
  end
end
