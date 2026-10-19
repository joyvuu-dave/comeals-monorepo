# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/initializers/verify_transaction_isolation.rb' do
  it 'passes on this suite, whose sessions are serializable' do
    expect { TransactionIsolationCheck.verify!(ActiveRecord::Base.connection) }.not_to raise_error
  end

  it 'refuses to boot when the sessions run at another level' do
    connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
    allow(connection).to receive(:select_value).with('SHOW default_transaction_isolation').and_return('read committed')

    expect { TransactionIsolationCheck.verify!(connection) }
      .to raise_error(RuntimeError, /Database sessions run at "read committed", not serializable/)
  end
end
