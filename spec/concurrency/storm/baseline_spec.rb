# frozen_string_literal: true

require 'rails_helper'

# Storm::Baseline against a transport that answers what each example
# needs, so no request reaches the app.
RSpec.describe Storm::Baseline do
  let(:plan) do
    resident = Struct.new(:id).new(7)
    Struct.new(:baseline_meal, :residents, :tokens)
          .new(Struct.new(:id).new(3), [resident], { 7 => 'token' })
  end

  # Answers 409 to the first `conflicts` requests, then 200.
  def transport_with(conflicts)
    sent = 0
    lambda do |_method, _path, _headers, _body, _ip|
      sent += 1
      sent <= conflicts ? [409, '{}'] : [200, '{}']
    end
  end

  # A SERIALIZABLE transaction that has written something and stays open
  # in another database on the same server makes PostgreSQL refuse the
  # baseline's writes until it ends (#218). Every try in that time is
  # refused, and the 10 tries in a row it used to allow take less than a
  # second.
  it 'waits out a run of refused writes longer than 10 tries' do
    result = described_class.call(plan: plan, transport: transport_with(15), network: '10.8.0', seconds: 0.2)

    expect(result.conflicts).to eq(15)
  end

  # It still gives up in the end, and says what else was open on the
  # server, since nothing in this database is.
  it 'gives up after give_up_after seconds of refused writes, and names the open transactions' do
    baseline = described_class.new(plan: plan, transport: transport_with(1_000), network: '10.8.0', give_up_after: 0.25)

    expect { baseline.call }.to raise_error(RuntimeError) do |error|
      expect(error.message).to start_with(
        'baseline post /api/v1/meals/3/residents/7 answered 409 for 0.25 seconds in a row. ' \
        'Open transactions on this server that have written something: '
      )
    end
  end
end
