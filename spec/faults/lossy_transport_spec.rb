# frozen_string_literal: true

require 'rails_helper'

# Part of the fault suite (challenge 30).
RSpec.describe Faults::LossyTransport do
  let(:sent) { [] }
  let(:inner) do
    lambda do |method, path, headers, body, _ip|
      sent << [method, path, headers, body]
      [sent.size == 1 ? 200 : 400, "answer #{sent.size}"]
    end
  end

  it 'loses the answer to a write and sends the same request again' do
    transport = described_class.new(inner, chance: 1.0, seed: 1)
    answer = transport.call(:post, '/api/v1/events', { 'Idempotency-Key' => '"k"' }, '{}', '10.0.0.1')

    expect(sent).to eq([[:post, '/api/v1/events', { 'Idempotency-Key' => '"k"' }, '{}']] * 2)
    expect(answer).to eq([400, 'answer 2'])
    expect(transport.resends).to eq([described_class::Resend.new(:post, '/api/v1/events', 200, 400, 'answer 2')])
  end

  it 'never loses the answer to a read' do
    transport = described_class.new(inner, chance: 1.0, seed: 1)
    transport.call(:get, '/api/v1/version', {}, nil, '10.0.0.1')

    expect(sent.size).to eq(1)
    expect(transport.resends).to be_empty
  end

  it 'loses nothing at a chance of 0' do
    transport = described_class.new(inner, chance: 0.0, seed: 1)
    transport.call(:post, '/api/v1/events', {}, '{}', '10.0.0.1')

    expect(sent.size).to eq(1)
  end
end
