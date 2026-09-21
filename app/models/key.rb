# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: keys
#
#  id            :bigint           not null, primary key
#  identity_type :string           not null
#  token         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  identity_id   :bigint           not null
#
# Indexes
#
#  index_keys_on_identity_type_and_identity_id  (identity_type,identity_id)
#  index_keys_on_token                          (token) UNIQUE
#

# A legacy API session. Login stopped creating Key rows when JWT auth
# shipped (app/services/jwt_auth.rb); no code writes this table anymore.
# It exists only so cookies issued before the JWT deploy keep working —
# ApiController#resolve_current_session falls back to a Key lookup when
# JWT decoding fails.
#
# Kept on purpose (decided 2026-09-21, #42 and #67). Removing the table
# and the fallback would gain nothing, and could sign out a person whose
# device still holds a pre-JWT token. Nothing here can tell which rows
# are still in use: the table has no last-used column. So this model,
# the table and the fallback stay for as long as the app runs.
class Key < ApplicationRecord
  has_secure_token
  belongs_to :identity, polymorphic: true
end
