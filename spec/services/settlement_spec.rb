# frozen_string_literal: true

require 'rails_helper'

# What a settlement does that its stored rows cannot show:
# settlement_contract_spec.rb reads only the rows, so it cannot see which
# rows were locked, how many times the meals were read, what was pushed
# to the screens, or the words of a refusal that only a broken part can
# cause. Mutant showed each of these free on 2026-09-28.
RSpec.describe Settlement do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }

  def settleable_meal(date)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    meal
  end

  describe 'the row lock' do
    # FOR UPDATE on the claimed meals is what makes an unlocked admin write
    # wait for the settlement and then be refused (issue #43). It must take
    # only those rows, so a settlement does not hold up a write to a meal
    # it is not settling, and in id order, so two settlements cannot
    # deadlock.
    it 'locks the meals it claims, and no others, in id order' do
      claimed = [settleable_meal(Date.yesterday - 2), settleable_meal(Date.yesterday - 1)]
      settleable_meal(community.today)
      statements = []
      record = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(record, 'sql.active_record') { settle! }

      locks = statements.grep(/\bFOR UPDATE\b/)
      expect(locks.size).to eq(1)
      expect(locks.first).to match(
        /FROM "meals" WHERE "meals"."id" IN \(\$1, \$2\) ORDER BY "meals"."id" ASC FOR UPDATE\z/
      )
      expect(Meal.where.not(reconciliation_id: nil)).to match_array(claimed)
    end
  end

  describe 'the ledger' do
    # The charge lines and the balances must come from one read of the
    # meals: two reads with a gap between them could see different rows,
    # and then the lines would not explain the balances.
    it 'builds one ledger, and writes the lines and the balances from it' do
      settleable_meal(Date.yesterday)
      allow(MealLedger).to receive(:new).and_call_original

      settle!

      expect(MealLedger).to have_received(:new).once
    end

    # insert_all without the bang skips a row that breaks a unique index
    # and says nothing (ON CONFLICT DO NOTHING). So a line already sitting
    # on the meal took the place of the real one. Here the stray line has
    # the same amount, so the meal still adds up to zero, and the
    # settlement would commit with a line it never wrote.
    it 'refuses to settle a meal that already holds a line in the place of a real one' do
      meal = settleable_meal(Date.yesterday)
      with_repair_bypass do
        MealCharge.create!(meal: meal, resident: eater, kind: 'debit', amount: BigDecimal('-30'),
                           multiplier: 2, unit_cost: BigDecimal('15'))
      end

      expect { settle! }.to raise_error(ActiveRecord::RecordNotUnique, /index_meal_charges_one_debit_per_attendee/)
    end
  end

  # While it writes the lines and the balances, a settlement sets a
  # database setting that names its reconciliation, and the database
  # refuses those inserts without it (spec/db/settled_ledger_inserts_spec.rb).
  # It must not outlive the write, or a later insert in the same
  # transaction would get through as if the settlement wrote it.
  describe 'the setting that lets it write the ledger' do
    def setting
      ActiveRecord::Base.connection.select_value("SELECT current_setting('#{described_class::SETTLING_SETTING}', true)")
    end

    it 'is off again once the ledger is written' do
      settleable_meal(Date.yesterday)

      ActiveRecord::Base.transaction do
        settle!
        expect(setting).to be_blank
      end
    end

    # The write runs in its own savepoint, and rolling that back also
    # undoes the setting. Without it, a caller that catches the error and
    # keeps its transaction would keep the setting too.
    it 'is off again when the write fails, even for a caller that catches the error' do
      settleable_meal(Date.yesterday)
      reconciliation = Reconciliation.new(end_date: Date.yesterday)
      allow(reconciliation).to receive(:settlement_balances).and_raise(RuntimeError, 'the write failed')

      ActiveRecord::Base.transaction do
        expect { described_class.new(reconciliation).settle! }.to raise_error(RuntimeError, 'the write failed')
        expect(setting).to be_blank
      end
    end
  end

  describe 'the screens after a settlement' do
    before do
      allow(Pusher).to receive(:trigger)
    end

    def pushes_to(channel)
      RSpec::Mocks.space.proxy_for(Pusher).messages_arg_list.count { |args| args.first == channel }
    end

    # The browser that asked for the settlement may have its own copies of
    # these meal pages, so it is told too: the push names no socket to
    # leave out, although the request has one.
    it "pushes each settled meal's page to every browser, the one that asked included" do
      meal = settleable_meal(Date.yesterday)
      Current.socket_id = '123.456'
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      settle!

      expect(Pusher).to have_received(:trigger).with("meal-#{meal.id}", 'update', { message: 'meal updated' }).once
    end

    it 'pushes no meal it did not settle' do
      settled = settleable_meal(Date.yesterday)
      open = settleable_meal(community.today)
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      settle!

      expect(pushes_to("meal-#{settled.id}")).to eq(1)
      expect(pushes_to("meal-#{open.id}")).to eq(0)
    end

    # The months are cleared and pushed together, after every meal is
    # noted, so a month two settled meals share is pushed once.
    it 'pushes a month once, however many of its meals it settled' do
      first = settleable_meal(Date.yesterday - 2)
      settleable_meal(Date.yesterday - 1)
      month = community.calendar_cache_key(first.date.year, first.date.month)
      RSpec::Mocks.space.proxy_for(Pusher).reset
      allow(Pusher).to receive(:trigger)

      settle!

      expect(pushes_to(month)).to eq(1)
    end
  end

  describe 'a preview of books that do not balance' do
    # A meal's lines always sum to zero, so this can only be reached by
    # replacing a part. The refusal must still say it came from a preview,
    # which has no reconciliation id of its own.
    it 'refuses to round them, and says it was a preview' do
      settleable_meal(Date.yesterday)
      allow(MealLedger).to receive(:new).and_wrap_original do |original, meals|
        original.call(meals).tap do |ledger|
          allow(ledger).to receive(:balances).and_return({ cook.id => BigDecimal('0.01') })
        end
      end

      expect { described_class.preview(cutoff: Date.yesterday) }
        .to raise_error(RuntimeError, /do not sum to zero for reconciliation preview\. Sum: 0\.01\./)
    end
  end
end
