# frozen_string_literal: true

require 'rails_helper'

# Part of the fault suite (challenge 30).
RSpec.describe Faults::Report do
  let(:resend) { Faults::LossyTransport::Resend }

  it 'names a route without its ids' do
    expect(described_class.route(:delete, '/api/v1/meals/12/residents/3/guests/40'))
      .to eq('DELETE /api/v1/meals/:id/residents/:id/guests/:id')
  end

  it 'finds a write that worked and was answered with an error when sent again' do
    resends = [resend.new(:post, '/api/v1/guest-room-reservations', 200, 400, '{"message":"taken"}'),
               resend.new(:post, '/api/v1/guest-room-reservations', 200, 400, '{"message":"taken"}'),
               resend.new(:patch, '/api/v1/meals/1/closed', 200, 200, '{}'),
               resend.new(:post, '/api/v1/meals/1/residents/2', 400, 400, '{}')]

    expect(described_class.error_for_a_saved_write(resends))
      .to eq(['POST /api/v1/guest-room-reservations: answered 400 when sent again after 200 (2x): ' \
              '{"message":"taken"}'])
  end

  it 'finds an event saved twice' do
    community = create(:community)
    create_list(:event, 2, title: 'storm-event-1-2', community: community)
    create(:event, title: 'storm-event-1-3', community: community)

    expect(described_class.saved_twice).to eq(['event storm-event-1-2 saved 2 times'])
  end
end
