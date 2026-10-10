# frozen_string_literal: true

require 'rails_helper'

# The three steps after a settlement commits — clear caches, refresh the
# running balances, mail the cooks — must all happen even when one of the
# outside services is down. The ledger is already written by then, so a
# raised error here would leave a settlement that happened with stale
# balances and no cook emails, a rake task that exits 1, and an API that
# answers 500 for a settlement that is in the database.
RSpec.describe SettleAndNotify do
  include ActiveJob::TestHelper

  # The cook mail is a job (NotifyCooksJob). Run it inline so these examples
  # see the whole of what a settlement does.
  around { |example| perform_enqueued_jobs { example.run } }

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain
  end

  def settleable_meal(date)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: resident, community: community)
    meal
  end

  it 'settles, refreshes balances, and mails the cooks' do
    settleable_meal(Date.yesterday)

    reconciliation = described_class.call(cutoff: Date.yesterday, community: community).reconciliation

    expect(reconciliation).to be_persisted
    expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
  end

  context 'when Pusher is down' do
    before { allow(Pusher).to receive(:trigger).and_raise(Pusher::HTTPError, 'Pusher is down') }

    it 'still refreshes balances and mails the cooks, and reports the outage' do
      settleable_meal(Date.yesterday)
      allow(Rails.error).to receive(:report).and_call_original

      reconciliation = described_class.call(cutoff: Date.yesterday, community: community).reconciliation

      expect(reconciliation).to be_persisted
      expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
      expect(Rails.error).to have_received(:report).with(an_instance_of(Pusher::HTTPError),
                                                         hash_including(handled: true)).at_least(:once)
    end

    it 'still clears every affected month from the calendar cache' do
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)
      # Two meals in two months, so the first month's failed push cannot
      # stop the second month's cache clear.
      settleable_meal(Date.yesterday)
      settleable_meal(Date.yesterday - 2.months)
      keys = [Date.yesterday, Date.yesterday - 2.months].map do |d|
        community.calendar_cache_key(d.year, d.month)
      end
      keys.each { |key| store.write(key, 'stale') }

      described_class.call(cutoff: Date.yesterday, community: community)

      keys.each { |key| expect(store.read(key)).to be_nil }
    end
  end

  # RetryOnConflict only retries at the outermost transaction, and under
  # transactional fixtures one is always open. So this one runs without.
  describe 'when the settlement keeps conflicting' do
    include_context 'with no test transaction'

    it 'gives up after three tries when the caller is a request, so nobody waits minutes' do
      settleable_meal(Date.yesterday)
      allow(RetryOnConflict).to receive(:sleep)
      allow(Settlement).to receive(:settle!).and_raise(ActiveRecord::SerializationFailure, 'conflict')

      expect { described_class.call(cutoff: Date.yesterday, community: community, retries: described_class::REQUEST) }
        .to raise_error(ActiveRecord::SerializationFailure)

      expect(Settlement).to have_received(:settle!).exactly(3).times
      # The request budget's delays: the base delay, then double it, each
      # stretched by up to half again (RetryOnConflict).
      base = described_class::REQUEST.base_delay
      expect(RetryOnConflict).to have_received(:sleep).with(be_between(base, base * 2)).once
      expect(RetryOnConflict).to have_received(:sleep).with(be_between(base * 2, base * 4)).once
    end

    # The whole point of the two budgets: what the nightly task waits out,
    # a request gives up on. The delays are the difference — ten tries from
    # a quarter second, doubling, is two to four minutes of sleeping, and
    # the web dyno serves one request at a time.
    it 'waits far longer for the nightly task than for a request' do
      expect(described_class::BATCH.attempts).to be > described_class::REQUEST.attempts
      expect(described_class::BATCH.base_delay).to be > described_class::REQUEST.base_delay
      expect(described_class::REQUEST.attempts).to eq(RetryOnConflict::MAX_ATTEMPTS)
      expect(described_class::REQUEST.base_delay).to eq(RetryOnConflict::BASE_DELAY)
    end

    it 'keeps trying past a request\'s three attempts, waiting the batch delay' do
      settleable_meal(Date.yesterday)
      sleeps = []
      allow(RetryOnConflict).to receive(:sleep) { |seconds| sleeps << seconds }
      failures = 0
      allow(Settlement).to receive(:settle!).and_wrap_original do |original, **args|
        failures += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if failures <= 6

        original.call(**args)
      end
      base = described_class::BATCH.base_delay

      reconciliation = described_class.call(cutoff: Date.yesterday, community: community).reconciliation

      expect(reconciliation).to be_persisted
      expect(failures).to eq(7)
      # The first wait, not any wait: with the request's delay the fifth
      # and sixth doublings land in the same range.
      expect(sleeps.first).to be_between(base, base * 2)
    end
  end

  # The refresh runs after the settlement has committed. A conflict there
  # (the nightly refresh job running at the same moment) is not the
  # settlement's: it is tried again, and if it keeps failing it is
  # reported and the call goes on to mail the cooks — the balances are a
  # cache the nightly job rebuilds (CLAUDE.md, money rule 6), and raising
  # would tell the caller "nothing was saved" about a settlement that is
  # in the database. Found by spec/concurrency/request_storm_spec.rb.
  describe 'when the balance refresh conflicts after the settlement committed' do
    include_context 'with no test transaction'

    before { allow(RetryOnConflict).to receive(:sleep) }

    it 'tries the refresh again' do
      settleable_meal(Date.yesterday)
      attempts = 0
      allow(BalanceRecalculation).to receive(:call).and_wrap_original do |original, **args|
        attempts += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if attempts < 3

        original.call(**args)
      end

      reconciliation = described_class.call(cutoff: Date.yesterday, community: community).reconciliation

      expect(reconciliation).to be_persisted
      expect(attempts).to eq(3)
      expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
    end

    it 'gives the nightly refresh the batch budget, so it outlasts the tries a request would make' do
      settleable_meal(Date.yesterday)
      sleeps = []
      allow(RetryOnConflict).to receive(:sleep) { |seconds| sleeps << seconds }
      attempts = 0
      allow(BalanceRecalculation).to receive(:call).and_wrap_original do |original, **args|
        attempts += 1
        raise ActiveRecord::SerializationFailure, 'conflict' if attempts <= described_class::REQUEST.attempts + 1

        original.call(**args)
      end
      allow(Rails.error).to receive(:report).and_call_original

      described_class.call(cutoff: Date.yesterday, community: community)

      expect(attempts).to eq(described_class::REQUEST.attempts + 2)
      base = described_class::BATCH.base_delay
      expect(sleeps.first).to be_between(base, base * 2)
      expect(Rails.error).not_to have_received(:report)
        .with(anything, hash_including(context: { step: 'balance refresh after settlement' }))
    end

    it 'gives the refresh the same patience as the settlement, and names the step when it gives up' do
      settleable_meal(Date.yesterday)
      allow(BalanceRecalculation).to receive(:call).and_raise(ActiveRecord::SerializationFailure, 'conflict')
      allow(Rails.error).to receive(:report).and_call_original

      described_class.call(cutoff: Date.yesterday, community: community, retries: described_class::REQUEST)

      expect(BalanceRecalculation).to have_received(:call).with(community: community)
                                                          .exactly(described_class::REQUEST.attempts).times
      base = described_class::REQUEST.base_delay
      expect(RetryOnConflict).to have_received(:sleep).with(be_between(base, base * 2)).once
      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ActiveRecord::SerializationFailure),
        hash_including(handled: true, severity: :error, context: { step: 'balance refresh after settlement' })
      )
    end

    it 'reports a refresh that keeps conflicting, and still returns the settlement and mails the cooks' do
      settleable_meal(Date.yesterday)
      allow(BalanceRecalculation).to receive(:call).and_raise(ActiveRecord::SerializationFailure, 'conflict')
      allow(Rails.error).to receive(:report).and_call_original

      reconciliation = described_class.call(cutoff: Date.yesterday, community: community).reconciliation

      expect(reconciliation).to be_persisted
      expect(Reconciliation.count).to eq(1)
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
      expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::SerializationFailure),
                                                         hash_including(handled: true, severity: :error))
    end
  end

  # Nothing after the commit may raise: the settlement is in the database
  # by then, and an error would reach a rescue that answers "Nothing was
  # saved". Each step reports its own error and the next one still runs.
  # A lock wait that ran out and a statement that ran too long are not
  # conflicts, so RetryOnConflict does not catch them, and nor did the
  # old rescue around the refresh. QueryCanceled can come from the
  # refresh's DEFERRABLE read, whose wait counts against the statement
  # timeout (SnapshotRead).
  describe 'when a step after the commit fails' do
    [ActiveRecord::LockWaitTimeout, ActiveRecord::QueryCanceled, RuntimeError].each do |error|
      it "reports a #{error.name} from the balance refresh and still returns the settlement" do
        settleable_meal(Date.yesterday)
        allow(BalanceRecalculation).to receive(:call).and_raise(error, 'refused')
        allow(Rails.error).to receive(:report).and_call_original

        settlement = described_class.call(cutoff: Date.yesterday, community: community)

        expect(settlement.reconciliation).to be_persisted
        expect(settlement.meal_count).to eq(1)
        expect(Rails.error).to have_received(:report).with(
          an_instance_of(error),
          hash_including(handled: true, severity: :error, context: { step: 'balance refresh after settlement' })
        )
      end
    end

    it 'reports an error from the cache clear, and still refreshes the balances' do
      settleable_meal(Date.yesterday)
      allow(LiveUpdate).to receive(:calendar).and_raise(ActiveRecord::QueryCanceled, 'canceling statement')
      allow(Rails.error).to receive(:report).and_call_original

      settlement = described_class.call(cutoff: Date.yesterday, community: community)

      expect(settlement.reconciliation).to be_persisted
      expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
      expect(Rails.error).to have_received(:report).with(
        an_instance_of(ActiveRecord::QueryCanceled),
        hash_including(handled: true, severity: :error, context: { step: 'cache clear after settlement' })
      )
    end
  end

  # The cook mail is queued in the settlement's own transaction. Solid
  # Queue keeps its jobs in this database, so the job row commits with
  # the settlement or not at all: a settlement that is saved always has
  # its cook mail queued, even when the process stops right after the
  # commit, and one that rolls back mails nobody. The real adapter here,
  # because the test adapter keeps jobs in memory, where a rollback
  # cannot reach them.
  describe 'the cook mail job, with Solid Queue' do
    include_context 'with no test transaction'
    include_context 'with Solid Queue as the job adapter'

    def queued_cook_mail
      SolidQueue::Job.where(class_name: 'NotifyCooksJob').map { |job| job.arguments.fetch('arguments') }
    end

    it 'is queued once for the settlement that was saved' do
      settleable_meal(Date.yesterday)

      settlement = described_class.call(cutoff: Date.yesterday, community: community)

      expect(queued_cook_mail).to eq([[{ '_aj_globalid' => settlement.reconciliation.to_global_id.to_s }]])
    end

    # ActiveJob answers false, and raises nothing, when an adapter refuses
    # a job through ActiveJob's own EnqueueError. Solid Queue 1.7 raises
    # its own error instead, but a settlement must not commit without its
    # mail either way.
    it 'rolls the settlement back when the job was not queued' do
      settleable_meal(Date.yesterday)
      allow(NotifyCooksJob).to receive(:perform_later).and_return(false)

      expect { described_class.call(cutoff: Date.yesterday, community: community) }
        .to raise_error(SettleAndNotify::MailNotQueued, 'The cook mail could not be queued, so nothing was settled.')

      expect(Reconciliation.count).to eq(0)
      expect(queued_cook_mail).to eq([])
    end

    # prosopite is off: the whole settlement runs twice on purpose, so
    # every one of its queries repeats once.
    it 'is rolled back with a settlement whose commit was refused, and queued once by the try that worked',
       prosopite: false do
      settleable_meal(Date.yesterday)
      allow(RetryOnConflict).to receive(:sleep)
      refused = false
      allow(NotifyCooksJob).to receive(:perform_later).and_wrap_original do |original, *args|
        job = original.call(*args)
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access'
        end
        job
      end

      settlement = described_class.call(cutoff: Date.yesterday, community: community)

      expect(Reconciliation.pluck(:id)).to eq([settlement.reconciliation.id])
      expect(queued_cook_mail).to eq([[{ '_aj_globalid' => settlement.reconciliation.to_global_id.to_s }]])
    end
  end

  it 'lets an error from the settlement itself through, so nothing is half done' do
    allow(Settlement).to receive(:settle!).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

    expect { described_class.call(cutoff: Date.yesterday, community: community) }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end
end
