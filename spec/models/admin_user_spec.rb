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
