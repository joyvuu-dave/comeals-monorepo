# frozen_string_literal: true

require 'rails_helper'

# The batching rules of LiveUpdate on their own. The contract every model
# keeps with it is pinned in spec/requests/api/v1/live_update_contract_spec.rb.
RSpec.describe LiveUpdate do
  let(:community) { create(:community) }

  before { community }

  describe '.calendar_range' do
    it 'notes nothing for a range with no start' do
      described_class.calendar_range(nil, Date.new(2026, 4, 1))

      expect(Pusher).not_to have_received(:trigger)
    end
  end

  describe '.batch' do
    it 'folds a batch opened inside another into the outer one, so there is one flush' do
      described_class.batch do
        described_class.batch { described_class.residents }
        described_class.residents
        expect(Pusher).not_to have_received(:trigger)
      end

      expect(Pusher).to have_received(:trigger)
        .with("community-#{community.id}-residents", 'update', { message: 'residents updated' }).once
    end
  end
end
