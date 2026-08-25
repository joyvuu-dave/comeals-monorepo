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
#  multiplier             :integer          default(2), not null
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
  include BelongsToTheCommunity

  include HasPhoneNumber

  # Ransack allowlists for ActiveAdmin filtering and sorting.
  # Deliberately excludes password_digest and reset_password_token.
  def self.ransackable_attributes(_auth_object = nil)
    %w[id active birthday can_cook created_at email multiplier name phone unit_id updated_at vegetarian]
  end

  attr_reader :password

  scope :adult, -> { where(multiplier: Multiplier::FULL..) }
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

  validates :multiplier, numericality: { only_integer: true }
  validates :name, presence: true

  # Names must be unique so every screen can tell residents apart (the
  # calendar, the audit log, and the mailers all show bare names). The
  # database enforces this too, with the case-insensitive unique index
  # index_residents_on_lower_name. This check is hand-written instead of
  # `uniqueness:` so the error can say who the clash is with and what to
  # do — a duplicate name can only be fixed at the moment someone tries
  # to create it, usually by the admin adding the second John Smith.
  validate :name_unique_with_helpful_message

  # Birthday is optional for adults: NULL means "adult, no birthday given" —
  # the nightly multiplier task skips them and the calendar shows nothing.
  # Children must have one so the task can move them to adult pricing as
  # they age. 1900-01-01 was the old placeholder for "adult, no birthday";
  # the exclusion keeps it from coming back through the admin datepicker,
  # and the residents_birthday_not_sentinel CHECK catches writes that skip
  # the model.
  validates :birthday, presence: { message: 'is required for children — pricing changes as they age' },
                       if: -> { multiplier < Multiplier::FULL }
  validates :birthday, exclusion: { in: [Date.new(1900, 1, 1)],
                                    message: 'cannot be the old 1900-01-01 placeholder — leave it blank instead' }

  VALID_EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
  validates :email, presence: true, length: { maximum: 255 },
                    format: { with: VALID_EMAIL_REGEX },
                    uniqueness: { case_sensitive: false }, allow_nil: true
  validate :email_presence

  before_validation :set_email
  before_save { self.email = email.downcase unless email.nil? }
  after_destroy :note_live_update
  after_save :revoke_all_sessions_if_password_changed
  after_save :note_live_update

  # PASSWORD STUFF
  def authenticate(unencrypted_password)
    SCrypt::Password.new(password_digest).is_password?(unencrypted_password) && self
  end

  # No length or presence rule, on purpose: a blank password is a feature
  # this community asked for. Admin creates children with '' (they have no
  # email, so they never log in), and an adult may reset their password to
  # '' and then log in with email alone. Do not add a validation here.
  def password=(unencrypted_password)
    @password = unencrypted_password
    self.password_digest = SCrypt::Password.create(unencrypted_password)
  end

  # Invalidate every outstanding session on password change. We hit both auth
  # paths because a user might have sessions of either kind — a legacy
  # opaque Key cookie from before the JWT deploy, a JWT issued after, or
  # both simultaneously (different devices in different eras).
  def revoke_all_sessions_if_password_changed
    return unless saved_change_to_password_digest?

    keys.destroy_all                                      # legacy Key sessions
    update_column(:keys_valid_since, Time.current)        # JWT sessions
  end

  # HELPERS
  def name_unique_with_helpful_message
    return if name.blank?

    clash = Resident.where('lower(name) = ?', name.downcase).where.not(id: id).first
    return if clash.nil?

    errors.add(:name, "is already used by the resident in unit #{clash.unit.name}. " \
                      'Add something people use to tell them apart — a middle name, ' \
                      'Jr./Sr., or a nickname.')
  end

  def email_presence
    errors.add(:email, 'cannot be blank.') if active && can_cook && multiplier >= Multiplier::FULL && email.nil?
  end

  def set_email
    self.email = nil if email == ''
  end

  # nil when no birthday is given (an adult who left it blank).
  def age
    return nil if birthday.nil?

    now = community.today
    had_birthday = now.month > birthday.month ||
                   (now.month == birthday.month && now.day >= birthday.day)
    now.year - birthday.year - (had_birthday ? 0 : 1)
  end

  # DERIVED DATA
  #
  # calc_balance and its helpers (bill_reimbursements, meal_resident_costs,
  # guest_costs) are the per-resident implementation of balance computation.
  # They are NOT used in production. Production computes every balance in
  # MealLedger, in one pass over preloaded meals.
  #
  # These methods are kept as a correctness oracle. Being a second, separately
  # written answer to the same question is the whole point of them: routing
  # them through MealLedger would make the specs below agree with themselves
  # and prove nothing.
  #   - spec/tasks/billing_recalculate_correctness_spec.rb compares the
  #     billing:recalculate output against calc_balance.
  #   - spec/tasks/settlement_matches_running_balance_spec.rb compares
  #     Reconciliation#settlement_balances against calc_balance too, so both
  #     of MealLedger's callers are checked against this oracle.
  #   - spec/models/resident_spec.rb tests the individual calculation logic.
  #
  # If you change financial logic in MealLedger, update these methods too
  # (and vice versa) — they must stay in sync.

  def calc_balance
    return BigDecimal('0') unless Meal.unreconciled.exists?

    bill_reimbursements - meal_resident_costs - guest_costs
  end

  def bill_reimbursements # rubocop:disable Metrics/PerceivedComplexity -- mirrors the settlement credit calculation; intentionally kept as a single auditable method
    relevant_bills = bills.joins(:meal).merge(Meal.unreconciled.with_attendees)
                          .where(no_cost: false)
                          .preload(meal: %i[bills meal_residents guests])

    relevant_bills.sum(BigDecimal('0')) do |bill|
      meal = bill.meal
      total_cost = meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
      next BigDecimal('0') if total_cost.zero?

      total_mult = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)
      # Zero total multiplier (child-only meal): nobody can be charged a
      # share, so the cook absorbs the cost and gets no credit. Mirrors the
      # total_mult.zero? branch in billing:recalculate and
      # Reconciliation#settlement_balances.
      next BigDecimal('0') if total_mult.zero?

      next bill.amount unless meal.capped?

      max_cost = meal.cap * total_mult
      if total_cost > max_cost
        (bill.amount / total_cost) * max_cost
      else
        bill.amount
      end
    end
  end

  def meal_resident_costs
    meal_residents.joins(:meal).merge(Meal.unreconciled)
                  .preload(meal: %i[bills meal_residents guests])
                  .sum(BigDecimal('0')) { |attendance| oracle_unit_cost(attendance.meal) * attendance.multiplier }
  end

  def guest_costs
    guests.joins(:meal).merge(Meal.unreconciled)
          .preload(meal: %i[bills meal_residents guests])
          .sum(BigDecimal('0')) { |guest| oracle_unit_cost(guest.meal) * guest.multiplier }
  end

  # The oracle's own per-unit cost, written out like bill_reimbursements
  # above: the debit side must not read MealLedger or any display code,
  # or the oracle would agree with the thing it exists to check.
  def oracle_unit_cost(meal)
    total_mult = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)
    return BigDecimal('0') if total_mult.zero?

    total_cost = meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
    if meal.capped?
      max_cost = meal.cap * total_mult
      total_cost = max_cost if total_cost > max_cost
    end
    total_cost / total_mult
  end

  # Balance is read from the cached resident_balances table (unreconciled preview).
  # The daily billing:recalculate rake task refreshes this value.
  # Signed: positive means the community owes this resident, negative means
  # they owe the community (the MealLedger sign convention). Show it to a
  # person only through BalanceDisplayHelper#balance_tag, never as a raw
  # signed number.
  def balance
    resident_balance&.amount || BigDecimal('0')
  end

  private

  # Columns no screen shows. A change to any other column — name, unit,
  # active, multiplier, birthday, vegetarian, can_cook, and whatever is
  # added next — is pushed on the residents channel: the hosts dropdown,
  # the meal page's sign-up list and every cached calendar month list
  # residents, so all of them refetch. A list of the shown columns would
  # go stale the first time a serializer gained one; this list only has
  # to name what is secret or invisible.
  UNSHOWN_COLUMNS = %w[email phone password_digest reset_password_token reset_password_sent_at
                       created_at updated_at].freeze
  private_constant :UNSHOWN_COLUMNS

  def note_live_update
    return unless destroyed? || (saved_changes.keys - UNSHOWN_COLUMNS).any?

    LiveUpdate.residents
  end
end
