# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LivePushJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  it 'pushes the channel with the update event and the data' do
    described_class.perform_now('meal-7', { message: 'meal updated' })

    expect(Pusher).to have_received(:trigger).with('meal-7', 'update', { message: 'meal updated' }).once
  end

  it 'passes the options through when there are any, so the sender is skipped' do
    described_class.perform_now('meal-7', { message: 'meal updated' }, { socket_id: 'the-sender' })

    expect(Pusher).to have_received(:trigger)
      .with('meal-7', 'update', { message: 'meal updated' }, { socket_id: 'the-sender' }).once
  end

  it 'keeps the socket id through the queue, where the arguments are serialized' do
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = false

    described_class.perform_later('meal-7', { message: 'meal updated' }, { socket_id: 'the-sender' })
    perform_enqueued_jobs

    expect(Pusher).to have_received(:trigger)
      .with('meal-7', 'update', { message: 'meal updated' }, { socket_id: 'the-sender' }).once
  end

  it 'tries a failing push three times and then reports it with the channel, without raising' do
    allow(Pusher).to receive(:trigger).and_raise(Pusher::HTTPError, 'Pusher is down')
    allow(Rails.error).to receive(:report)

    expect { described_class.perform_later('meal-7', { message: 'meal updated' }) }.not_to raise_error

    expect(Pusher).to have_received(:trigger).exactly(described_class::ATTEMPTS).times
    expect(Rails.error).to have_received(:report)
      .with(an_instance_of(Pusher::HTTPError), hash_including(handled: true, context: { channel: 'meal-7' })).once
  end

  it 'schedules the next try a few seconds later, not at once, so a short Pusher outage passes' do
    allow(Pusher).to receive(:trigger).and_raise(Pusher::HTTPError, 'Pusher is down')
    adapter = ActiveJob::Base.queue_adapter
    adapter.perform_enqueued_at_jobs = false

    freeze_time do
      described_class.perform_later('meal-7', { message: 'meal updated' })

      retry_job = adapter.enqueued_jobs.last
      expect(retry_job[:job]).to eq(described_class)
      expect(retry_job[:at]).to be_within(1).of((Time.current + described_class::WAIT).to_f)
    end
  end
end
