# frozen_string_literal: true

# == Schema Information
#
# Table name: residents
#
#  id                     :bigint           not null, primary key
#  active                 :boolean          default(TRUE), not null
#  birthday               :date
#  can_cook               :boolean          default(TRUE), not null
#  email                  :string
#  keys_valid_since       :datetime         not null
#  multiplier             :integer          default(2), not null
#  name                   :string           not null
#  password_digest        :string           not null
#  phone                  :string
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  vegetarian             :boolean          default(FALSE), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  community_id           :bigint           not null
#  unit_id                :bigint           not null
#
# Indexes
#
#  index_residents_on_lower_email           (lower((email)::text)) UNIQUE
#  index_residents_on_lower_name            (lower((name)::text)) UNIQUE
#  index_residents_on_reset_password_token  (reset_password_token) UNIQUE
#  index_residents_on_unit_id               (unit_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (unit_id => units.id)
#
require 'rails_helper'

RSpec.describe Resident do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------
  describe '#authenticate' do
    it 'returns the resident on correct password' do
      resident = create(:resident, community: community, unit: unit, password: 'secret123')
      expect(resident.authenticate('secret123')).to eq(resident)
    end

    it 'returns false on incorrect password' do
      resident = create(:resident, community: community, unit: unit, password: 'secret123')
      expect(resident.authenticate('wrong')).to be_falsey
    end
  end

  describe '#password=' do
    it 'sets password_digest via SCrypt' do
      resident = build(:resident, community: community, unit: unit)
      resident.password = 'newpassword'

      expect(resident.password_digest).to be_present
      expect(resident.password_digest).not_to eq('newpassword')
      expect(SCrypt::Password.new(resident.password_digest).is_password?('newpassword')).to be true
    end
  end

  describe '#revoke_all_sessions_if_password_changed' do
    it 'destroys every outstanding Key row on password change' do
      resident = create(:resident, community: community, unit: unit, password: 'initial')
      resident.keys.create!
      resident.keys.create!
      expect(resident.keys.count).to eq(3)

      resident.password = 'changed'
      resident.save!

      expect(resident.reload.keys).to be_empty
    end

    it 'advances keys_valid_since past any previously-issued JWT' do
      resident = create(:resident, community: community, unit: unit, password: 'initial')
      before = resident.keys_valid_since

      resident.password = 'changed'
      resident.save!

      expect(resident.reload.keys_valid_since).to be > before
    end

    it 'leaves sessions alone when other attributes change' do
      resident = create(:resident, community: community, unit: unit, password: 'initial')
      original_ids = resident.keys.pluck(:id).sort
      original_valid_since = resident.keys_valid_since

      resident.update!(name: "Renamed #{SecureRandom.hex(3)}")

      expect(resident.reload.keys.pluck(:id).sort).to eq(original_ids)
      expect(resident.keys_valid_since).to eq(original_valid_since)
    end
  end

  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------
  describe '#email_presence' do
    it 'requires email for active, cookable adults' do
      resident = build(:resident, community: community, unit: unit,
                                  active: true, can_cook: true, multiplier: 2, email: nil)

      expect(resident).not_to be_valid
      expect(resident.errors[:email]).to include('cannot be blank.')
    end

    it 'allows nil email for children (multiplier < 2)' do
      resident = build(:resident, community: community, unit: unit,
                                  active: true, can_cook: true, multiplier: 1, email: nil)

      expect(resident).to be_valid
    end

    it 'allows nil email for inactive residents' do
      resident = build(:resident, community: community, unit: unit,
                                  active: false, can_cook: true, multiplier: 2, email: nil)

      expect(resident).to be_valid
    end

    it 'allows nil email for residents who cannot cook' do
      resident = build(:resident, community: community, unit: unit,
                                  active: true, can_cook: false, multiplier: 2, email: nil)

      expect(resident).to be_valid
    end
  end

  describe 'name uniqueness' do
    let(:other_unit) { create(:unit, community: community, name: 'B7') }

    it 'refuses a duplicate name and says who the clash is with and what to do' do
      create(:resident, community: community, unit: other_unit, name: 'John Smith')
      resident = build(:resident, community: community, unit: unit, name: 'John Smith')

      expect(resident).not_to be_valid
      expect(resident.errors[:name].first).to eq(
        'is already used by the resident in unit B7. Add something people use to ' \
        'tell them apart — a middle name, Jr./Sr., or a nickname.'
      )
    end

    it 'treats names as the same regardless of case, matching the database index' do
      create(:resident, community: community, unit: other_unit, name: 'John Smith')
      resident = build(:resident, community: community, unit: unit, name: 'john smith')

      expect(resident).not_to be_valid
      expect(resident.errors[:name].first).to include('unit B7')
    end

    it 'lets a resident keep their own name on update' do
      resident = create(:resident, community: community, unit: unit, name: 'John Smith')
      resident.email = 'john.smith@example.com'

      expect(resident).to be_valid
    end
  end

  describe 'email uniqueness' do
    let(:other_unit) { create(:unit, community: community, name: 'B7') }

    it 'treats emails as the same regardless of case, matching the database index' do
      create(:resident, community: community, unit: other_unit, email: 'john@example.com')
      resident = build(:resident, community: community, unit: unit, email: 'John@Example.com')

      expect(resident).not_to be_valid
      expect(resident.errors[:email]).to include('has already been taken')
    end

    it 'refuses a duplicate email at the database even when validations are skipped' do
      create(:resident, community: community, unit: other_unit, email: 'john@example.com')
      resident = create(:resident, community: community, unit: unit, email: 'jane@example.com')

      expect { resident.update_column(:email, 'John@Example.com') }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'birthday validation' do
    it 'allows an adult with no birthday' do
      resident = build(:resident, community: community, unit: unit, multiplier: 2, birthday: nil)

      expect(resident).to be_valid
    end

    it 'requires a birthday for children so they age into adult pricing' do
      resident = build(:resident, community: community, unit: unit, multiplier: 1, birthday: nil)

      expect(resident).not_to be_valid
      expect(resident.errors[:birthday]).to include('is required for children — pricing changes as they age')
    end

    it 'rejects the old 1900-01-01 placeholder' do
      resident = build(:resident, community: community, unit: unit,
                                  multiplier: 2, birthday: Date.new(1900, 1, 1))

      expect(resident).not_to be_valid
      expect(resident.errors[:birthday])
        .to include('cannot be the old 1900-01-01 placeholder — leave it blank instead')
    end
  end

  describe '#set_email' do
    it 'converts empty string email to nil' do
      resident = create(:resident, community: community, unit: unit,
                                   active: true, can_cook: false, multiplier: 2, email: '')

      expect(resident.email).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Age
  # ---------------------------------------------------------------------------
  describe '#age' do
    it 'returns correct age for a birthday in the past' do
      resident = create(:resident, community: community, unit: unit,
                                   birthday: Date.new(1990, 1, 1))

      expected = Time.zone.today.year - 1990 - (Time.zone.today >= Date.new(Time.zone.today.year, 1, 1) ? 0 : 1)
      expect(resident.age).to eq(expected)
    end

    it 'returns age before birthday this year' do
      # Birthday hasn't happened yet this year
      future_birthday = Time.zone.today + 30
      resident = create(:resident, community: community, unit: unit,
                                   birthday: Date.new(2000, future_birthday.month, future_birthday.day))

      expect(resident.age).to eq(Time.zone.today.year - 2000 - 1)
    end

    it 'returns age on birthday' do
      resident = create(:resident, community: community, unit: unit,
                                   birthday: Date.new(2000, Time.zone.today.month, Time.zone.today.day))

      expect(resident.age).to eq(Time.zone.today.year - 2000)
    end

    it 'returns nil for an adult with no birthday' do
      resident = create(:resident, community: community, unit: unit, birthday: nil)

      expect(resident.age).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Calendar cache invalidation
  # ---------------------------------------------------------------------------
  describe 'after_commit :invalidate_calendar_cache_if_birthday_changed' do
    let(:this_year) { Time.zone.today.year }

    before { allow(community).to receive(:invalidate_calendar_cache) }

    it 'invalidates only the new month when a birthday is set for the first time' do
      resident = create(:resident, community: community, unit: unit, birthday: nil)

      resident.update!(birthday: Date.new(1990, 6, 15))

      expect(community).to have_received(:invalidate_calendar_cache)
        .with(Date.new(this_year, 6, 1)).once
    end

    it 'invalidates only the old month when a birthday is cleared' do
      resident = create(:resident, community: community, unit: unit,
                                   birthday: Date.new(1990, 6, 15))

      resident.update!(birthday: nil)

      # Once for the create (new month), once for the clear (old month).
      expect(community).to have_received(:invalidate_calendar_cache)
        .with(Date.new(this_year, 6, 1)).twice
    end

    it 'invalidates both months when a birthday moves' do
      resident = create(:resident, community: community, unit: unit,
                                   birthday: Date.new(1990, 3, 10))

      resident.update!(birthday: Date.new(1990, 4, 10))

      expect(community).to have_received(:invalidate_calendar_cache)
        .with(Date.new(this_year, 3, 1)).twice # create + old month of the move
      expect(community).to have_received(:invalidate_calendar_cache)
        .with(Date.new(this_year, 4, 1)).once
    end
  end

  # ---------------------------------------------------------------------------
  # Real-time notifications
  # ---------------------------------------------------------------------------
  describe 'after_commit :notify_residents_update' do
    # Pusher is stubbed silently across all examples. Positive assertions use
    # `.at_least(:once)`; negative assertions use `.exactly(:once)` to allow
    # the single trigger from the initial `create` while forbidding any
    # further trigger from the mutation under test.
    let(:expected_channel) { "community-#{community.id}-residents" }

    # Filter by the `residents updated` message so this spec is decoupled
    # from Unit#notify_residents_update (which emits `unit updated` on the
    # same channel and runs when a `let(:unit)` is lazily created).
    def expect_resident_triggers(count)
      expect(Pusher).to have_received(:trigger).with(
        expected_channel,
        'update',
        hash_including(message: 'residents updated')
      ).exactly(count).times
    end

    before { allow(Pusher).to receive(:trigger) }

    it 'triggers on create' do
      create(:resident, community: community, unit: unit)
      expect_resident_triggers(1)
    end

    it 'triggers on destroy' do
      resident = create(:resident, community: community, unit: unit)
      resident.destroy!
      expect_resident_triggers(2)
    end

    # One example per column the hosts query depends on. If any of these
    # stop firing, a real-time host-list change will be missed.
    {
      name: ->(r, _) { r.update!(name: 'Renamed') },
      active: ->(r, _) { r.update!(active: false) },
      multiplier: ->(r, _) { r.update!(multiplier: r.multiplier + 1) },
      unit_id: ->(r, other_unit) { r.update!(unit: other_unit) }
    }.each do |column, mutation|
      it "triggers on #{column} change" do
        other_unit = create(:unit, community: community)
        resident = create(:resident, community: community, unit: unit)
        mutation.call(resident, other_unit)
        expect_resident_triggers(2)
      end
    end

    # Non-hosts-relevant columns must NOT produce a Pusher round-trip on
    # every save (prevents broadcast storms on password rotations, token
    # refreshes, birthday edits, email changes, and can_cook toggles —
    # none of those affect the hosts endpoint's output).
    it 'does not trigger on password-only change' do
      resident = create(:resident, community: community, unit: unit, password: 'secret123')
      resident.update!(password: 'newsecret456')
      expect_resident_triggers(1)
    end

    it 'does not trigger on birthday-only change' do
      resident = create(:resident, community: community, unit: unit)
      resident.update!(birthday: Date.new(1990, 6, 15))
      expect_resident_triggers(1)
    end

    it 'does not trigger on vegetarian-only change' do
      resident = create(:resident, community: community, unit: unit)
      resident.update!(vegetarian: !resident.vegetarian)
      expect_resident_triggers(1)
    end

    it 'does not trigger on email-only change' do
      resident = create(:resident, community: community, unit: unit)
      resident.update!(email: 'new@example.com')
      expect_resident_triggers(1)
    end

    it 'does not trigger on can_cook-only change' do
      resident = create(:resident, community: community, unit: unit)
      resident.update!(can_cook: !resident.can_cook)
      expect_resident_triggers(1)
    end

    it 'does not raise if Pusher is unavailable' do
      allow(Pusher).to receive(:trigger).and_raise(StandardError, 'pusher down')
      expect do
        create(:resident, community: community, unit: unit)
      end.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe 'scopes' do
    describe '.adult' do
      it 'returns residents with multiplier >= 2' do
        adult = create(:resident, community: community, unit: unit, multiplier: 2)
        child = create(:resident, community: community, unit: unit, multiplier: 1)
        baby = create(:resident, community: community, unit: unit, multiplier: 0)

        adults = described_class.adult
        expect(adults).to include(adult)
        expect(adults).not_to include(child)
        expect(adults).not_to include(baby)
      end
    end

    describe '.active' do
      it 'returns only active residents' do
        active = create(:resident, community: community, unit: unit, active: true)
        inactive = create(:resident, community: community, unit: unit, active: false,
                                     can_cook: false, email: nil)

        actives = described_class.active
        expect(actives).to include(active)
        expect(actives).not_to include(inactive)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Derived data (financial)
  # ---------------------------------------------------------------------------
  describe '#calc_balance' do
    it 'returns 0 when there are no unreconciled meals' do
      resident = create(:resident, community: community, unit: unit)
      expect(resident.calc_balance).to eq(BigDecimal('0'))
    end

    it 'returns 0 for a cook who attends their own meal (single adult)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: cook, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.reload

      # Credit (reimbursement) exactly equals debit (attendance charge)
      expect(cook.calc_balance).to eq(BigDecimal('0'))
    end

    it 'gives a positive balance to a cook who does not attend' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      attendee = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: attendee, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.reload

      expect(cook.calc_balance).to eq(BigDecimal('50'))
    end

    it 'gives a negative balance to an attendee who does not cook' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      attendee = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: attendee, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.reload

      # Attendee owes the full meal cost (only attendee, multiplier 2, unit_cost = 50/2 = 25, charge = 25*2 = 50)
      expect(attendee.calc_balance).to eq(BigDecimal('-50'))
    end

    it 'splits cost proportionally between adults and children' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      adult = create(:resident, community: community, unit: unit, multiplier: 2)
      child = create(:resident, community: community, unit: unit, multiplier: 1)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: adult, community: community)
      create(:meal_resident, meal: meal, resident: child, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      # multiplier = 2 + 1 = 3
      # unit_cost = 30 / 3 = 10
      # adult charge = 10 * 2 = 20
      # child charge = 10 * 1 = 10
      expect(adult.calc_balance).to eq(BigDecimal('-20'))
      expect(child.calc_balance).to eq(BigDecimal('-10'))
    end

    it 'excludes reconciled meals from balance' do
      reconciliation = create(:reconciliation, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)

      # Reconciled meal — should be excluded. Build children first, then flip
      # reconciliation_id via update_columns (bypasses callbacks); models now
      # reject saves when meal.reconciled?.
      reconciled_meal = create(:meal, community: community)
      create(:meal_resident, meal: reconciled_meal, resident: resident, community: community)
      create(:bill, meal: reconciled_meal, resident: resident, community: community,
                    amount: BigDecimal('99'))
      reconciled_meal.update_columns(reconciliation_id: reconciliation.id)

      # Unreconciled meal — should be included
      unreconciled_meal = create(:meal, community: community)
      create(:meal_resident, meal: unreconciled_meal, resident: resident, community: community)
      create(:bill, meal: unreconciled_meal, resident: resident, community: community,
                    amount: BigDecimal('30'))

      reconciled_meal.reload
      unreconciled_meal.reload

      # Balance should only reflect the unreconciled meal (cook + attend = 0)
      expect(resident.calc_balance).to eq(BigDecimal('0'))
    end

    it 'correctly sums across multiple unreconciled meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal1 = create(:meal, community: community)
      create(:meal_resident, meal: meal1, resident: eater, community: community)
      create(:bill, meal: meal1, resident: cook, community: community, amount: BigDecimal('40'))
      meal1.reload

      meal2 = create(:meal, community: community)
      create(:meal_resident, meal: meal2, resident: eater, community: community)
      create(:bill, meal: meal2, resident: cook, community: community, amount: BigDecimal('60'))
      meal2.reload

      # Cook: reimbursed 40 + 60 = 100, no attendance charges
      expect(cook.calc_balance).to eq(BigDecimal('100'))

      # Eater: charged for both meals (sole attendee each time, so full cost)
      expect(eater.calc_balance).to eq(BigDecimal('-100'))
    end

    it 'charges guest costs to the hosting resident' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      host = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: host, community: community)
      create(:guest, meal: meal, resident: host, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      meal.reload

      # multiplier = host(2) + guest(2) = 4
      # unit_cost = 60 / 4 = 15
      # host meal charge = 15 * 2 = 30
      # host guest charge = 15 * 2 = 30
      # total host owes = -60
      expect(host.calc_balance).to eq(BigDecimal('-60'))
    end

    it 'handles capped meals correctly (cook reimbursed at capped rate)' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      meal = create(:meal, community: capped_community)

      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('20'))
      meal.reload

      # multiplier = 2, cap = 5.00, max_cost = 10.00
      # total_cost = 20, exceeds cap → subsidized
      # effective_total_cost = 10.00
      # unit_cost = 10 / 2 = 5.00
      # eater charge = 5 * 2 = 10
      # cook credit = (20 / 20) * 10 = 10 (capped, not raw 20)
      # cook balance = 10 - 0 = 10
      # eater balance = 0 - 10 = -10
      # books balance: 10 - 10 = 0 ✓
      expect(cook.calc_balance).to eq(BigDecimal('10'))
      expect(eater.calc_balance).to eq(BigDecimal('-10'))
    end

    it 'credits the cook nothing for a child-only meal (zero total multiplier)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      meal = create(:meal, community: community)

      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      meal.reload

      # total_mult = 0 → nobody can be charged a share, so the cook absorbs
      # the cost and is not reimbursed. Must match billing:recalculate and
      # Reconciliation#settlement_balances, which zero the meal on
      # total_mult.zero?. Books balance: everyone at 0.
      expect(cook.calc_balance).to eq(BigDecimal('0'))
      expect(baby.calc_balance).to eq(BigDecimal('0'))
    end

    it 'balances sum to zero with multiple cooks and attendees' do
      cook_a = create(:resident, community: community, unit: unit, multiplier: 2)
      cook_b = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: cook_a, community: community)
      create(:meal_resident, meal: meal, resident: cook_b, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook_a, community: community, amount: BigDecimal('30'))
      create(:bill, meal: meal, resident: cook_b, community: community, amount: BigDecimal('20'))
      meal.reload

      balance_a = cook_a.calc_balance
      balance_b = cook_b.calc_balance
      balance_eater = eater.calc_balance

      # Total credits must equal total debits within sub-micropenny precision.
      # BigDecimal repeating decimals (50/6) create negligible artifacts that
      # largest-remainder allocation absorbs at settlement time.
      total = balance_a + balance_b + balance_eater
      expect(total.abs).to be < BigDecimal('0.00000001')
    end
  end

  describe '#balance' do
    it 'reads from resident_balances cache, not from calc_balance' do
      resident = create(:resident, community: community, unit: unit, multiplier: 2)

      # Manually set a cached balance
      ResidentBalance.create!(resident: resident, amount: BigDecimal('42.50'))

      # balance should return the cached value, not recompute
      expect(resident.balance).to eq(BigDecimal('42.50'))
    end

    it 'returns 0 when no cached balance exists' do
      resident = create(:resident, community: community, unit: unit)
      expect(resident.balance).to eq(BigDecimal('0'))
    end
  end

  # ---------------------------------------------------------------------------
  # Deletion safeguards
  # ---------------------------------------------------------------------------
  describe 'deletion' do
    let(:resident) { create(:resident, community: community, unit: unit) }

    # Ledger rows are permanent, so a resident who has any can never be
    # deleted — only marked inactive. One example per ledger association.
    it 'cannot be destroyed with a bill' do
      meal = create(:meal, community: community)
      bill = create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      expect(resident.destroy).to be false
      expect(resident.errors[:base]).to include('Cannot delete record because dependent bills exist')
      expect(described_class.exists?(resident.id)).to be true
      expect(Bill.exists?(bill.id)).to be true
    end

    it 'cannot be destroyed with meal attendance' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect(resident.destroy).to be false
      expect(resident.errors[:base]).to include('Cannot delete record because dependent meal residents exist')
      expect(described_class.exists?(resident.id)).to be true
    end

    it 'cannot be destroyed while hosting guests' do
      meal = create(:meal, community: community)
      create(:guest, meal: meal, resident: resident)

      expect(resident.destroy).to be false
      expect(resident.errors[:base]).to include('Cannot delete record because dependent guests exist')
      expect(described_class.exists?(resident.id)).to be true
    end

    it 'cannot be destroyed with a reconciliation balance' do
      reconciliation = create(:reconciliation, community: community)
      create(:reconciliation_balance, reconciliation: reconciliation, resident: resident)

      expect(resident.destroy).to be false
      expect(resident.errors[:base])
        .to include('Cannot delete record because dependent reconciliation balances exist')
      expect(described_class.exists?(resident.id)).to be true
    end

    it 'cannot be destroyed with a settlement line item' do
      # A real charge always comes with a bill or attendance, which would
      # trip their own guards first. Inserting one directly isolates this
      # association's guard.
      meal = create(:meal, community: community)
      MealCharge.create!(meal: meal, resident: resident, kind: 'debit',
                         amount: BigDecimal('-8'), unit_cost: BigDecimal('4'), multiplier: 2)

      expect(resident.destroy).to be false
      expect(resident.errors[:base]).to include('Cannot delete record because dependent meal charges exist')
      expect(described_class.exists?(resident.id)).to be true
    end

    it 'cannot be destroyed even after being marked inactive' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      resident.update!(active: false)

      expect(resident.destroy).to be false
      expect(described_class.exists?(resident.id)).to be true
    end

    it 'raises from destroy! when ledger rows exist' do
      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: resident, community: community)

      expect { resident.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
      expect(described_class.exists?(resident.id)).to be true
    end

    # The model guard runs in callbacks, which delete/delete_all skip. The
    # database foreign key is the last line of defense. The savepoint keeps
    # the raised error from poisoning the spec's wrapping transaction.
    it 'is protected by the database foreign key when callbacks are skipped' do
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      expect do
        ActiveRecord::Base.transaction(requires_new: true) { resident.delete }
      end.to raise_error(ActiveRecord::InvalidForeignKey)
      expect(described_class.exists?(resident.id)).to be true
    end

    # A resident with no ledger rows (one created by mistake) can still be
    # destroyed. Sessions, the balance cache, and reservations go with them —
    # none of that is ledger data.
    it 'can be destroyed with no ledger rows, taking sessions, balance cache, and reservations along' do
      ResidentBalance.create!(resident: resident, amount: BigDecimal('0'))
      create(:guest_room_reservation, resident: resident, community: community)
      create(:common_house_reservation, resident: resident, community: community)
      key_ids = resident.keys.ids
      expect(key_ids).not_to be_empty

      resident_id = resident.id
      expect { resident.destroy! }.to change(described_class, :count).by(-1)

      expect(Key.where(id: key_ids)).to be_empty
      expect(ResidentBalance.where(resident_id: resident_id)).to be_empty
      expect(GuestRoomReservation.where(resident_id: resident_id)).to be_empty
      expect(CommonHouseReservation.where(resident_id: resident_id)).to be_empty
    end
  end

  describe 'phone' do
    it_behaves_like 'a model with a phone number' do
      let(:record) { build(:resident, community: community, unit: unit) }
    end
  end
end
