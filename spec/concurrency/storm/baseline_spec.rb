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
end
