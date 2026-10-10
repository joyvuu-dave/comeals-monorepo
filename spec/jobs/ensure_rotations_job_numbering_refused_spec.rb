# frozen_string_literal: true

require 'rails_helper'

# A new rotation gets its number (place_value, the calendar chip's
# "Rotation 5") from Rotation#set_place_value. Until 2026-10-10 that ran
# after the rotation's commit. At SERIALIZABLE the database can refuse
# any statement (ADR 0005), and a refusal there left the rotation saved
# with no number. The job then tried its run again, found the calendar
# long enough, and made nothing more, so the calendar showed the rotation
# with no number until the next rotation was made or deleted. Now the
# number is written in the rotation's own transaction, and a refusal
# takes the rotation back with it. No test transaction, so the rotation
# really commits or rolls back.
RSpec.describe EnsureRotationsJob do
  context 'when the database refuses a new rotation number once' do
    include_context 'with no test transaction'

    let!(:community) { create(:community) }

    before do
      allow(Healthcheck).to receive(:ping)
      allow(Rails.error).to receive(:report)
    end

    it 'leaves every rotation with a number' do
      # A calendar one day short of six months, so the job makes one rotation.
      create(:meal, community: community, rotation: create(:rotation, community: community),
                    date: community.today + 6.months - 1.day)
      refused = false
      # rubocop:disable-next RSpec/AnyInstance
      allow_any_instance_of(Rotation).to receive(:set_place_value).and_wrap_original do |original|
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access'
        end
        original.call
      end

      described_class.perform_now

      expect(Rotation.count).to eq(2)
      expect(Rotation.order(:id).pluck(:place_value)).to eq([1, 2])
    end
  end
end
