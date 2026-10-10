# frozen_string_literal: true

require 'rails_helper'

# == Schema Information
#
# Table name: guest_add_keys
#
#  id          :bigint           not null, primary key
#  key         :text             not null
#  vegetarian  :boolean          not null
#  created_at  :datetime         not null
#  guest_id    :bigint
#  meal_id     :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_guest_add_keys_on_created_at       (created_at)
#  index_guest_add_keys_on_guest_id         (guest_id)
#  index_guest_add_keys_on_meal_id_and_key  (meal_id,key) UNIQUE
#  index_guest_add_keys_on_resident_id      (resident_id)
#
# Foreign Keys
#
#  fk_rails_...  (guest_id => guests.id) ON DELETE => nullify
#  fk_rails_...  (meal_id => meals.id) ON DELETE => cascade
#  fk_rails_...  (resident_id => residents.id) ON DELETE => cascade
#
# The key of a guest add that was written (S2), kept like a bills save's
# key (BillsSaveKey, ADR 0009). The rules for the table itself are in
# spec/db/guest_add_keys_spec.rb.
RSpec.describe GuestAddKey do
  let(:community) { create(:community) }
  let(:meal) { create(:meal, community: community) }
  let(:host) { create(:resident, community: community) }

  def key_made_at(time, key, guest: nil)
    described_class.create!(meal: meal, key: key, resident: host, vegetarian: false, guest: guest, created_at: time)
  end

  describe '.delete_expired' do
    let(:now) { Time.zone.parse('2026-10-09 12:00:00') }

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

    # The delete runs at SERIALIZABLE beside guest adds, which look up a
    # key and then add one, so PostgreSQL can refuse it for a conflict. It
    # is tried again, with the same tries and waits as RecurringJob gives
    # a scheduled job, so that hour's run does not fail.
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

  it 'belongs to its meal, its host and the guest it added' do
    guest = create(:guest, meal: meal, resident: host)
    key = key_made_at(Time.current, 'k', guest: guest)

    expect([key.meal, key.resident, key.guest]).to eq([meal, host, guest])
  end

  # The guest is removed while the key is kept, so a row without one is
  # a row like any other.
  it 'needs no guest' do
    expect(key_made_at(Time.current, 'k').guest).to be_nil
  end

  # What a guest add sent again with this key is answered with
  # (GuestReplayedSerializer). The page shows the guest in its host's row
  # as the guest the tap asked for, so it must still be that guest: the
  # same host's, on the same meal.
  describe '#guest_as_added' do
    let(:guest) { create(:guest, meal: meal, resident: host) }
    let!(:key) { key_made_at(Time.current, 'k', guest: guest) }

    it 'is the guest the add made, while it is still a guest of that host on this meal' do
      expect(key.guest_as_added).to eq(guest)
    end

    it 'is nil once that guest was removed' do
      guest.destroy!

      expect(key.reload.guest_as_added).to be_nil
    end

    it 'is nil once that guest was given another host' do
      guest.update!(resident: create(:resident, community: community))

      expect(key.reload.guest_as_added).to be_nil
    end

    it 'is nil once that guest was moved to another meal' do
      guest.update!(meal: create(:meal, community: community))

      expect(key.reload.guest_as_added).to be_nil
    end
  end
end
