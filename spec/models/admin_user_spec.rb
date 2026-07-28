# frozen_string_literal: true

# == Schema Information
#
# Table name: admin_users
#
#  id                     :bigint           not null, primary key
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :inet
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :inet
#  remember_created_at    :datetime
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  sign_in_count          :integer          default(0), not null
#  superuser              :boolean          default(FALSE), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  community_id           :bigint
#
# Indexes
#
#  index_admin_users_on_email                 (email) UNIQUE
#  index_admin_users_on_reset_password_token  (reset_password_token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
require 'rails_helper'

RSpec.describe AdminUser do
  let(:community) { create(:community) }

  describe '#superuser?' do
    it 'returns true when superuser is true' do
      admin = create(:admin_user, community: community, superuser: true)
      expect(admin.superuser?).to be true
    end

    it 'returns false when superuser is false' do
      admin = create(:admin_user, community: community, superuser: false)
      expect(admin.superuser?).to be false
    end
  end

  # A community with zero superusers cannot recover from inside the app:
  # settling, ledger edits, and granting the flag are all superuser actions,
  # so there is nobody left who can promote anybody.
  describe 'keeping at least one superuser' do
    it 'refuses to demote the last superuser' do
      last = create(:admin_user, community: community, superuser: true)

      expect(last.update(superuser: false)).to be false
      expect(last.reload.superuser).to be true
      expect(last.errors[:superuser].join).to include('last superuser')
    end

    it 'refuses to destroy the last superuser' do
      last = create(:admin_user, community: community, superuser: true)

      expect { last.destroy }.not_to change(described_class, :count)
      expect(described_class.exists?(last.id)).to be true
      expect(last.errors[:base].join).to include('last superuser')
    end

    it 'allows demoting a superuser while another remains' do
      create(:admin_user, community: community, superuser: true)
      other = create(:admin_user, community: community, superuser: true)

      expect(other.update(superuser: false)).to be true
      expect(other.reload.superuser).to be false
    end

    it 'allows destroying a superuser while another remains' do
      create(:admin_user, community: community, superuser: true)
      other = create(:admin_user, community: community, superuser: true)

      expect { other.destroy }.to change(described_class, :count).by(-1)
    end

    it 'does not interfere with plain admins' do
      create(:admin_user, community: community, superuser: true)
      plain = create(:admin_user, community: community, superuser: false)

      expect(plain.update(email: 'moved@example.com')).to be true
      expect { plain.destroy }.to change(described_class, :count).by(-1)
    end

    it 'allows an unrelated update to the last superuser' do
      last = create(:admin_user, community: community, superuser: true)

      expect(last.update(email: 'still-here@example.com')).to be true
    end
  end

  # The model guards give a readable error in the UI. The trigger is what
  # holds when callbacks are skipped — update_all, delete_all, psql.
  describe 'the database backstop' do
    # The raise aborts the enclosing transaction, so the statement runs inside
    # a savepoint. Without it the assertions after the raise hit
    # PG::InFailedSqlTransaction rather than reading the row.
    def in_savepoint(&)
      described_class.transaction(requires_new: true, &)
    end

    it 'refuses an update_all that would demote the last superuser' do
      last = create(:admin_user, community: community, superuser: true)

      expect do
        in_savepoint { described_class.where(id: last.id).update_all(superuser: false) }
      end.to raise_error(ActiveRecord::StatementInvalid, /last superuser/)

      expect(last.reload.superuser).to be true
    end

    it 'refuses a delete that would remove the last superuser' do
      last = create(:admin_user, community: community, superuser: true)

      expect do
        in_savepoint { described_class.where(id: last.id).delete_all }
      end.to raise_error(ActiveRecord::StatementInvalid, /last superuser/)

      expect(described_class.exists?(last.id)).to be true
    end

    it 'allows the same writes while another superuser remains' do
      create(:admin_user, community: community, superuser: true)
      other = create(:admin_user, community: community, superuser: true)

      expect { described_class.where(id: other.id).update_all(superuser: false) }.not_to raise_error
      expect { described_class.where(id: other.id).delete_all }.not_to raise_error
    end
  end

  describe '#admin_users' do
    it 'returns all admin users' do
      admin1 = create(:admin_user, community: community)
      admin2 = create(:admin_user, community: community)

      result = admin1.admin_users
      expect(result).to include(admin1, admin2)
    end
  end

  describe '#communities' do
    it 'returns the singleton community' do
      admin = create(:admin_user, community: community)

      expect(admin.communities).to eq([community])
    end
  end

  describe 'bootstrap flow' do
    # These tests document the fresh-deploy setup flow: operator creates the
    # first admin in `rails c` on an empty DB, then creates the singleton
    # Community via ActiveAdmin. community_id is nullable during that window
    # and the Community after_create hook backfills orphan admins.

    it 'allows creating an admin without a community during bootstrap' do
      admin = described_class.new(email: 'bootstrap@example.com',
                                  password: 'password',
                                  password_confirmation: 'password')

      expect(admin.save).to be true
      expect(admin.community_id).to be_nil
    end

    it 'backfills orphan admins when the singleton Community is created' do
      orphan = described_class.create!(email: 'bootstrap@example.com',
                                       password: 'password',
                                       password_confirmation: 'password')
      expect(orphan.community_id).to be_nil

      singleton = create(:community)

      expect(orphan.reload.community_id).to eq(singleton.id)
    end
  end
end
