# frozen_string_literal: true

# Every data migration that turns off the DDL transaction has the same
# with_retry method: when PostgreSQL refuses its transaction for a conflict
# with another write, it tries again, up to ATTEMPTS times in all, waiting
# a little longer each time. It does not try again inside a transaction
# someone else opened, because the refusal ended that whole transaction.
#
# The example's own transaction is open here, so the examples that try
# again tell the migration it is not.
RSpec.shared_examples 'a data migration that tries a conflict again' do |migration_class|
  let(:retrying_migration) { migration_class.new }
  let(:conflict) { ActiveRecord::SerializationFailure.new('could not serialize access') }

  def with_retry_output(migration, &)
    out = StringIO.new
    $stdout = out
    result = migration.send(:with_retry, &)
    [result, out.string]
  ensure
    $stdout = STDOUT
  end

  before { allow(retrying_migration).to receive(:sleep) }

  it 'tries again after a conflict and returns what the block returns' do
    allow(retrying_migration.connection).to receive(:transaction_open?).and_return(false)
    tries = 0

    result, output = with_retry_output(retrying_migration) do
      tries += 1
      raise conflict if tries == 1

      :done
    end

    expect([result, tries]).to eq([:done, 2])
    expect(output).to include('Trying again (2 of 5)')
    expect(retrying_migration).to have_received(:sleep).with(0.2).once
  end

  it 'tries again after a lock wait timeout too' do
    allow(retrying_migration.connection).to receive(:transaction_open?).and_return(false)
    tries = 0

    result, = with_retry_output(retrying_migration) do
      tries += 1
      raise ActiveRecord::LockWaitTimeout if tries == 1

      :done
    end

    expect([result, tries]).to eq([:done, 2])
  end

  it 'gives up and raises the conflict after the last try' do
    allow(retrying_migration.connection).to receive(:transaction_open?).and_return(false)
    tries = 0

    expect do
      with_retry_output(retrying_migration) do
        tries += 1
        raise conflict
      end
    end.to raise_error(ActiveRecord::SerializationFailure)
    expect(tries).to eq(migration_class::ATTEMPTS)
  end

  it 'raises at once when the conflict comes inside an open transaction' do
    tries = 0

    expect do
      with_retry_output(retrying_migration) do
        tries += 1
        raise conflict
      end
    end.to raise_error(ActiveRecord::SerializationFailure)
    expect(tries).to eq(1)
    expect(retrying_migration).not_to have_received(:sleep)
  end
end
