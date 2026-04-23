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

# An API session. Each login creates a new Key; revocation is just destroying
# the row. Identity is polymorphic so admin sessions could slot in later.
class Key < ApplicationRecord
  has_secure_token
  belongs_to :identity, polymorphic: true

  def set_token
    self.token = self.class.generate_unique_secure_token
  end
end
