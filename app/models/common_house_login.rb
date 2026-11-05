# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: common_house_logins
#
#  id               :bigint           not null, primary key
#  keys_valid_since :datetime         not null
#  password_digest  :string           not null
#  singleton_guard  :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_common_house_logins_on_singleton_guard  (singleton_guard) UNIQUE
#

# The login of the shared screen in the Common House. It is not a
# Resident on purpose: nothing that lists residents (cooks, sign-ups,
# balances) can list it, so none of them needs an exception for it. An
# audit row names it as its author (user_type "CommonHouseLogin"), and the
# history shows that as "Common House".
#
# There is at most one row (singleton_guard, as on Community). Only
# admins know the password, so unlike a resident's it may not be blank.
class CommonHouseLogin < ApplicationRecord
  extend T::Sig

  MINIMUM_PASSWORD_LENGTH = 12

  # What the headers call the screen ("logout Common House").
  NAME = 'Common House'

  # What the screen types in the email box of the resident sign-in form.
  # It ends in .invalid, which RFC 2606 keeps from ever being a real
  # domain, so no mail can reach anyone through it. No resident may have
  # a .invalid address (Resident#email_not_reserved and the CHECK
  # residents_email_not_invalid_domain), so a sign-in with this address
  # is always this login.
  EMAIL = 'common-house@comeals.invalid'
  ALREADY_EXISTS = 'There is already a Common House login. Change its password instead.'

  validate :enforce_singleton, on: :create
  validates :password_digest, presence: true
  validate :password_long_enough
  # Checked only when a confirmation is given (Rails skips a nil one), so
  # the admin form, which always sends one, is checked, and the console is
  # not made to type the password twice.
  validates :password, confirmation: true

  # The history names this row, so it stays. To sign the screen out,
  # change the password.
  before_destroy { throw :abort }

  after_save :revoke_all_sessions_if_password_changed

  sig { params(unencrypted_password: T.nilable(String)).returns(T.any(FalseClass, CommonHouseLogin)) }
  def authenticate(unencrypted_password)
    return false if unencrypted_password.nil?

    SCrypt::Password.new(T.must(password_digest)).is_password?(unencrypted_password) ? self : false
  end

  # The password typed in this object's life, for the validations. Never
  # read from the database: only the digest is stored.
  sig { returns(T.nilable(String)) }
  attr_reader :password

  sig { params(unencrypted_password: String).void }
  def password=(unencrypted_password)
    @password = T.let(unencrypted_password, T.nilable(String))
    self.password_digest = SCrypt::Password.create(unencrypted_password)
  end

  SECRET_COLUMNS = T.let(%w[password_digest keys_valid_since].freeze, T::Array[String])
  private_constant :SECRET_COLUMNS

  # Removed from the result, not added to options[:except], so a caller's
  # only: or methods: cannot bring a secret column back.
  sig { params(options: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T::Hash[String, T.untyped]) }
  def serializable_hash(options = nil)
    super.except(*SECRET_COLUMNS)
  end

  private

  sig { void }
  def enforce_singleton
    return unless CommonHouseLogin.exists?

    errors.add(:base, ALREADY_EXISTS)
  end

  # @password is set only when a password was given in this object's
  # life, so a save that changes nothing else is not checked again.
  sig { void }
  def password_long_enough
    return if @password.nil? && persisted?
    return if @password.to_s.length >= MINIMUM_PASSWORD_LENGTH

    errors.add(:password, "must be at least #{MINIMUM_PASSWORD_LENGTH} characters")
  end

  sig { void }
  def revoke_all_sessions_if_password_changed
    return unless saved_change_to_password_digest?

    update_column(:keys_valid_since, Time.current)
  end
end
