# frozen_string_literal: true

require 'rails_helper'

# == Schema Information
#
# Table name: bills_save_keys
#
#  id           :bigint           not null, primary key
#  edits_sha256 :text             not null
#  key          :text             not null
#  created_at   :datetime         not null
#  meal_id      :bigint           not null
#
# Indexes
#
#  index_bills_save_keys_on_created_at       (created_at)
#  index_bills_save_keys_on_meal_id_and_key  (meal_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (meal_id => meals.id) ON DELETE => cascade
#
# The key of a bills save that was written (decision 6 of #135, ADR 0009).
# The rules for the table itself are in spec/db/bills_save_keys_spec.rb.
RSpec.describe BillsSaveKey do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:fingerprint) { Digest::SHA256.hexdigest('[]') }

  def key_made_at(time, key)
    described_class.create!(meal: meal, key: key, edits_sha256: fingerprint, created_at: time)
  end

  describe '.delete_expired' do
    let(:now) { Time.zone.parse('2026-10-07 12:00:00') }

    it 'deletes the keys made more than 7 days ago, keeps the rest, and says how many it deleted' do
      key_made_at(now - 7.days - 1.second, 'just-over')
      key_made_at(now - 30.days, 'long-ago')
      key_made_at(now - 7.days, 'exactly-seven-days')
      key_made_at(now - 1.minute, 'new')

      expect(described_class.delete_expired(now: now)).to eq(2)
      expect(described_class.pluck(:key)).to contain_exactly('exactly-seven-days', 'new')
    end

    it 'reads the time now when it is not given one' do
      key_made_at(8.days.ago, 'old')
      key_made_at(6.days.ago, 'new')

      described_class.delete_expired

      expect(described_class.pluck(:key)).to eq(['new'])
    end

    # The delete runs at SERIALIZABLE, and so does a bills save, which
    # looks up its key and then adds one. While the table is small,
    # PostgreSQL reads all of it for that look-up, so a save that commits
    # while the delete runs makes PostgreSQL refuse the delete (ADR 0009).
    # The delete is tried again, with the same tries and waits as
    # RecurringJob gives a scheduled job, so that hour's job does not fail.
    describe 'when PostgreSQL refuses the delete for a conflict' do
      include_context 'with no test transaction'

      before { allow(RetryOnConflict).to receive(:sleep) }

      it 'tries again, and deletes the old keys' do
        key_made_at(now - 8.days, 'old')
        key_made_at(now - 1.minute, 'new')
        refused = false
        allow_any_instance_of(ActiveRecord::Relation).to receive(:delete_all).and_wrap_original do |original| # rubocop:disable RSpec/AnyInstance -- delete_expired builds the relation
          unless refused
            refused = true
            raise ActiveRecord::SerializationFailure, 'could not serialize access'
          end

          original.call
        end

        expect(described_class.delete_expired(now: now)).to eq(1)
        expect(described_class.pluck(:key)).to eq(['new'])
      end

      it 'waits as long as a scheduled job does: five tries from a quarter second' do
        allow(RetryOnConflict).to receive(:call).and_call_original

        described_class.delete_expired(now: now)

        expect(RetryOnConflict).to have_received(:call).with(attempts: 5, base_delay: 0.25)
      end
    end
  end

  it 'keeps a key for 7 days' do
    expect(described_class::KEPT_FOR).to eq(7.days)
  end

  it 'belongs to its meal' do
    key = key_made_at(Time.current, 'k')

    expect(key.meal).to eq(meal)
  end
end
