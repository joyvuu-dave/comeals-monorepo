# frozen_string_literal: true

require 'rails_helper'

# == Schema Information
#
# Table name: mail_deliveries
#
#  id          :bigint           not null, primary key
#  about_type  :string           not null
#  mailer      :string           not null
#  sent_at     :datetime         not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  about_id    :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_mail_deliveries_on_resident_id  (resident_id)
#  index_mail_deliveries_one_per_person  (mailer,about_type,about_id,resident_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (resident_id => residents.id)
#
RSpec.describe MailDelivery do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:ann) { create(:resident, community: community, unit: unit) }
  let(:bob) { create(:resident, community: community, unit: unit) }
  let(:rotation) { create(:rotation, community: community) }

  it 'answers who has not been mailed yet, per mailer and per record' do
    other_rotation = create(:rotation, community: community)
    described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann)
    described_class.record!(mailer: 'rotation_signup_email', about: rotation, resident: bob)
    described_class.record!(mailer: 'new_rotation_email', about: other_rotation, resident: bob)

    left = described_class.not_yet_sent(Resident.where(id: [ann.id, bob.id]), mailer: 'new_rotation_email',
                                                                              about: rotation)
    expect(left).to contain_exactly(bob)
  end

  it 'refuses a second row for the same person, mailer, and record' do
    described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann)

    expect { described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann) }
      .to raise_error(ActiveRecord::RecordInvalid, /already been taken/)
    expect do
      described_class.insert_all!([{ mailer: 'new_rotation_email', about_type: 'Rotation', about_id: rotation.id,
                                     resident_id: ann.id, sent_at: Time.current,
                                     created_at: Time.current, updated_at: Time.current }])
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # The row is written after the mail went out. A refusal for a conflict
  # that ends the run leaves a person mailed with no row, and the next run
  # mails them again (spec/jobs/notify_cooks_job_spec.rb shows the whole
  # path). So a conflict is tried again, like any other refused write.
  # No test transaction: a retry can only happen outside one.
  context 'when the database refuses the row once for a conflict' do
    include_context 'with no test transaction'

    it 'writes it on the next try' do
      allow(Rails.error).to receive(:report)
      refused = false
      allow(described_class).to receive(:create!).and_wrap_original do |original, **attributes|
        unless refused
          refused = true
          raise ActiveRecord::SerializationFailure, 'could not serialize access'
        end
        original.call(**attributes)
      end

      row = described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann)

      expect(row).to be_persisted
      expect(described_class.where(mailer: 'new_rotation_email', about: rotation).pluck(:resident_id)).to eq([ann.id])
      expect(described_class).to have_received(:create!).twice
    end
  end

  it 'refuses an update at the database' do
    row = described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann)
    expect { row.update_columns(sent_at: 1.day.ago) }
      .to raise_error(ActiveRecord::StatementInvalid, /UPDATE on mail_deliveries refused/)
  end

  it 'refuses a delete at the database' do
    row = described_class.record!(mailer: 'new_rotation_email', about: rotation, resident: ann)
    expect { row.delete }.to raise_error(ActiveRecord::StatementInvalid, /DELETE on mail_deliveries refused/)
  end
end
