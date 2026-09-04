# typed: true
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
#  phone                  :string
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

class AdminUser < ApplicationRecord
  include HasPhoneNumber

  # Ransack allowlists for ActiveAdmin sorting.
  # Deliberately excludes encrypted_password, reset_password_token,
  # reset_password_sent_at, and IP address fields.
  def self.ransackable_attributes(_auth_object = nil)
    %w[id created_at current_sign_in_at email last_sign_in_at phone remember_created_at sign_in_count
       superuser updated_at]
  end

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable,
         :recoverable, :rememberable, :trackable, :validatable

  # community_id is nullable so an operator can create the bootstrap admin in
  # `rails c` on an empty database, then create the singleton Community via
  # ActiveAdmin. Community#after_create backfills orphan admins, so post-setup
  # every AdminUser points at the one community.
  #
  # Not BelongsToTheCommunity: that concern calls Community.instance, which
  # raises on an empty database. Community.first is nil there, and nil is
  # allowed here.
  belongs_to :community, optional: true
  before_validation { self.community ||= Community.first }

  # No has_many :through sugar here on purpose. This is a
  # single-community app: an admin's "units" are just
  # Community.instance.units, and nine pass-through associations
  # implied a per-admin scoping that has never existed (#51).

  # A community must always keep at least one superuser. Without one, nobody
  # can settle a reconciliation, touch a bill, or promote anyone — and nobody
  # can promote themselves out of it either, because promotion is itself a
  # superuser action. The only way back would be shell access to the dyno,
  # which for a community running its own copy means calling us.
  #
  # Both guards are prepended for the same reason Meal and Reconciliation
  # prepend theirs (issue #26): dependent callbacks registered by associations
  # run first otherwise, so a swallowed inner rollback can leave partial
  # writes behind. A database trigger backstops both paths — see
  # 20260728120000_refuse_removing_the_last_superuser.rb.
  before_update :refuse_demoting_last_superuser, prepend: true
  before_destroy :refuse_destroying_last_superuser, prepend: true

  def superuser?
    superuser
  end

  # Admin users have no name column. Audit history displays the audit
  # user's name (AuditSerializer), so show the email — it says who acted.
  def name
    email
  end

  private

  def refuse_demoting_last_superuser
    return unless superuser_changed?(from: true, to: false)
    return if other_superuser_exists?

    errors.add(:superuser, 'cannot be removed from the last superuser — the community would ' \
                           'have no one able to settle reconciliations or grant admin access.')
    throw(:abort)
  end

  def refuse_destroying_last_superuser
    return unless superuser?
    return if other_superuser_exists?

    errors.add(:base, 'This is the last superuser. Promote another admin first, otherwise the ' \
                      'community would have no one able to settle reconciliations or grant ' \
                      'admin access.')
    throw(:abort)
  end

  def superuser_changed?(from:, to:)
    superuser_previously_was = attribute_was(:superuser)
    superuser_previously_was == from && superuser == to
  end

  def other_superuser_exists?
    AdminUser.where(superuser: true).where.not(id: id).exists?
  end
end
