# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: residents
#
#  id                     :bigint           not null, primary key
#  active                 :boolean          default(TRUE), not null
#  birthday               :date
#  can_cook               :boolean          default(TRUE), not null
#  can_reconcile          :boolean          default(FALSE), not null
#  email                  :string
#  keys_valid_since       :datetime         not null
#  name                   :string           not null
#  password_digest        :string           not null
#  phone                  :string
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  vegetarian             :boolean          default(FALSE), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  community_id           :bigint           not null
#  unit_id                :bigint           not null
#
# Indexes
#
#  index_residents_on_lower_email           (lower((email)::text)) UNIQUE
#  index_residents_on_lower_name            (lower((name)::text)) UNIQUE
#  index_residents_on_reset_password_token  (reset_password_token) UNIQUE
#  index_residents_on_unit_id               (unit_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (unit_id => units.id)
#

class Resident < ApplicationRecord
  extend T::Sig

  include BelongsToTheCommunity

  include HasPhoneNumber

  # Ransack allowlists for ActiveAdmin filtering and sorting.
  # Deliberately excludes password_digest and reset_password_token.
  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_attributes(_auth_object = nil)
    %w[id active birthday can_cook created_at email name phone unit_id updated_at vegetarian]
  end

  sig { returns(T.nilable(String)) }
  attr_reader :password

  # A price band is not stored. It comes from the birthday and the
  # community's two ages, for a date (Community#multiplier_for_age); a
  # resident with no birthday is an adult. Attendance snapshots the band
  # for the meal's date at sign-up (MealResident#set_multiplier), so a
  # later birthday never changes a past charge. Until 2026-09-26 the band
  # was a column that a nightly job copied from the birthday, so a
  # person's price was wrong from their birthday until the next run, and
  # a sign-up months ahead used the sign-up day's band (#88). The column
  # stays one release for the rollback story (strong_migrations); nothing
  # reads or writes it, so after a rollback the old release must run its
  # rake residents:set_multiplier at once (docs/runbooks/scheduler-cutover.md).
  self.ignored_columns += %w[multiplier]

  # The same rule as #age_on, in SQL: full-price age reached on the day,
  # a February 29 birthday counting on March 1 in a non-leap year (the
  # month-day text compares the way the Ruby does). Pinned against the
  # Ruby rule for every day of a leap year and a non-leap year in
  # spec/models/resident_price_band_spec.rb.
  scope :adult_on, lambda { |date, community: Community.instance|
    where('residents.birthday IS NULL OR ' \
          '(EXTRACT(YEAR FROM ?::date) - EXTRACT(YEAR FROM residents.birthday) - ' \
          "CASE WHEN to_char(?::date, 'MMDD') < to_char(residents.birthday, 'MMDD') THEN 1 ELSE 0 END) >= ?",
          date, date, community.full_price_age)
  }
  scope :adult, -> { adult_on(Community.instance.today) }
  scope :active, -> { where(active: true) }
  # Who can be asked to cook: active adults with can_cook set. The rotation
  # log lists these.
  scope :eligible_cooks, -> { active.adult.where(can_cook: true) }

  belongs_to :unit

  # Ledger rows are permanent. A resident who has any of these can never be
  # deleted — mark them inactive instead. restrict_with_error makes destroy
  # fail with a clear error instead of silently deleting open-meal rows or
  # hitting a raw foreign key error on reconciled ones. Declared before the
  # destroy cascades below so these checks run first.
  has_many :bills, dependent: :restrict_with_error
  has_many :meal_residents, dependent: :restrict_with_error
  has_many :meals, through: :meal_residents
  has_many :guests, dependent: :restrict_with_error
  has_many :reconciliation_balances, dependent: :restrict_with_error
  has_many :meal_charges, dependent: :restrict_with_error

  # Not ledger data: login sessions, the rebuildable balance cache, and
  # reservations (freely edited and deleted in the app). These go with the
  # resident. Only a resident with no ledger rows — one created by mistake —
  # can be destroyed at all.
  has_many :keys, as: :identity, dependent: :destroy
  has_one :resident_balance, dependent: :destroy
  has_many :guest_room_reservations, dependent: :destroy
  has_many :common_house_reservations, dependent: :destroy
  # A record that one email went out to this person. Append-only by
  # database trigger (comeals_protect_mail_delivery), so a resident who has
  # one can only be retired, never deleted.
  has_many :mail_deliveries, dependent: :restrict_with_error

  validates :name, presence: true

  # Names must be unique so every screen can tell residents apart (the
  # calendar, the audit log, and the mailers all show bare names). The
  # database enforces this too, with the case-insensitive unique index
  # index_residents_on_lower_name. This check is hand-written instead of
  # `uniqueness:` so the error can say who the clash is with and what to
  # do — a duplicate name can only be fixed at the moment someone tries
  # to create it, usually by the admin adding the second John Smith.
  validate :name_unique_with_helpful_message

  # Birthday is optional: NULL means an adult who gave none, and the
  # calendar shows nothing for them. A child needs one, so the price
  # follows their age; the admin form says which the person is (`kind`,
  # below) so a child without a birthday is refused instead of priced as
  # an adult. 1900-01-01 was the old placeholder for "adult, no birthday";
  # the exclusion keeps it from coming back through the admin datepicker,
  # and the residents_birthday_not_sentinel CHECK catches writes that skip
  # the model.
  validates :birthday, exclusion: { in: [Date.new(1900, 1, 1)],
                                    message: 'cannot be the old 1900-01-01 placeholder — leave it blank instead' }
  # A birthday after today would be a negative age, and a negative age is
  # under every band's floor: the person would eat free (review, 2026-09-26).
  validate :birthday_not_in_the_future

  # The admin form's statement about the person, "adult" or "child", not
  # stored: the birthday and the community's ages are the facts, and this
  # is checked against them on save so the form cannot say one thing and
  # the birthday another. Blank (the API, a factory, the console) means
  # no statement, and only the birthday counts.
  KINDS = T.let(%w[adult child].freeze, T::Array[String])
  attribute :kind, :string
  validates :kind, inclusion: { in: KINDS }, allow_nil: true
  validate :kind_matches_birthday, if: :kind_stated?

  VALID_EMAIL_REGEX = T.let(/\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i, Regexp)
  validates :email, presence: true, length: { maximum: 255 },
                    format: { with: VALID_EMAIL_REGEX },
                    uniqueness: { case_sensitive: false }, allow_nil: true
  validate :email_presence

  before_validation :set_email
  before_save { self.email = email&.downcase }
  after_destroy :note_live_update
  after_save :revoke_all_sessions_if_password_changed
  after_save :note_live_update

  # Priced below a full adult share today.
  sig { returns(T::Boolean) }
  def child?
    multiplier_on(T.must(community).today) < Multiplier::FULL
  end

  # The price band on a date: what a sign-up for a meal on that date is
  # charged at. No birthday means an adult.
  sig { params(date: Date).returns(Integer) }
  def multiplier_on(date)
    T.must(community).multiplier_for_age(age_on(date))
  end

  # PASSWORD STUFF
  sig { params(unencrypted_password: T.nilable(String)).returns(T.any(FalseClass, Resident)) }
  def authenticate(unencrypted_password)
    SCrypt::Password.new(T.must(password_digest)).is_password?(unencrypted_password) ? self : false
  end

  # No length or presence rule, on purpose: a blank password is a feature
  # this community asked for. Admin creates children with '' (they have no
  # email, so they never log in), and an adult may reset their password to
  # '' and then log in with email alone. Do not add a validation here.
  #
  # The digest itself must exist, though: a resident created without ever
  # assigning a password (only the console can do that) gets a validation
  # error here instead of a NOT NULL error from the database.
  validates :password_digest, presence: true
  sig { params(unencrypted_password: String).void }
  def password=(unencrypted_password)
    @password = T.let(unencrypted_password, T.nilable(String))
    self.password_digest = SCrypt::Password.create(unencrypted_password)
  end

  # Invalidate every outstanding session on password change. We hit both auth
  # paths because a user might have sessions of either kind — a legacy
  # opaque Key cookie from before the JWT deploy, a JWT issued after, or
  # both simultaneously (different devices in different eras).
  sig { void }
  def revoke_all_sessions_if_password_changed
    return unless saved_change_to_password_digest?

    keys.destroy_all                                      # legacy Key sessions
    update_column(:keys_valid_since, Time.current)        # JWT sessions
  end

  # HELPERS
  sig { void }
  def name_unique_with_helpful_message
    name = self.name
    return if name.blank?

    clash = Resident.where('lower(name) = ?', name.downcase).where.not(id: id).first
    return if clash.nil?

    errors.add(:name, "is already used by the resident in unit #{T.must(clash.unit).name}. " \
                      'Add something people use to tell them apart — a middle name, ' \
                      'Jr./Sr., or a nickname.')
  end

  sig { void }
  def email_presence
    errors.add(:email, 'cannot be blank.') if active && can_cook && !child? && email.nil?
  end

  sig { void }
  def birthday_not_in_the_future
    birthday = self.birthday
    return if birthday.nil? || birthday <= T.must(community).today

    errors.add(:birthday, 'cannot be after today.')
  end

  sig { returns(T::Boolean) }
  def kind_stated?
    KINDS.include?(kind)
  end

  sig { void }
  def kind_matches_birthday
    if kind == 'child'
      return errors.add(:birthday, 'is needed for a child, so the price follows their age.') if birthday.nil?

      errors.add(:birthday, 'makes this person an adult. Choose Adult, or check the date.') unless child?
    elsif birthday.present? && child?
      errors.add(:birthday, 'makes this person a child. Choose Child, or check the date.')
    end
  end

  sig { void }
  def set_email
    self.email = nil if email == ''
  end

  # nil when no birthday is given (an adult who left it blank).
  sig { returns(T.nilable(Integer)) }
  def age
    age_on(T.must(community).today)
  end

  # The age on a date, counted the way people count: a year is added on
  # the birthday itself, and a February 29 birthday is added on March 1
  # in a year with no February 29. The adult_on scope says the same in
  # SQL.
  sig { params(date: Date).returns(T.nilable(Integer)) }
  def age_on(date)
    birthday = self.birthday
    return nil if birthday.nil?

    had_birthday = date.month > birthday.month ||
                   (date.month == birthday.month && date.day >= birthday.day)
    date.year - birthday.year - (had_birthday ? 0 : 1)
  end

  # Balance is read from the cached resident_balances table (unreconciled preview).
  # The daily billing:recalculate rake task refreshes this value.
  # Signed: positive means the community owes this resident, negative means
  # they owe the community (the MealLedger sign convention). Show it to a
  # person only through BalanceDisplayHelper#balance_tag, never as a raw
  # signed number.
  sig { returns(BigDecimal) }
  def balance
    resident_balance&.amount || BigDecimal('0')
  end

  private

  # Columns no screen shows. A change to any other column — name, unit,
  # active, birthday, vegetarian, can_cook, and whatever is added next —
  # is pushed on the residents channel: the hosts dropdown, the meal
  # page's sign-up list and every cached calendar month list residents,
  # so all of them refetch. A list of the shown columns would go stale
  # the first time a serializer gained one; this list only has to name
  # what is secret or invisible. The writes that skip this callback
  # (keys_valid_since, the reset-token columns) touch nothing a screen
  # shows. A birthday moves someone into the adult band on its own, with
  # no write at all, so the SPA refetches the hosts list at midnight.
  UNSHOWN_COLUMNS = T.let(%w[email phone password_digest reset_password_token reset_password_sent_at
                             created_at updated_at].freeze, T::Array[String])
  private_constant :UNSHOWN_COLUMNS

  sig { void }
  def note_live_update
    return unless destroyed? || (saved_changes.keys - UNSHOWN_COLUMNS).any?

    LiveUpdate.residents
  end
end
