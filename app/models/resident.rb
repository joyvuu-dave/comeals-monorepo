# frozen_string_literal: true

# == Schema Information
#
# Table name: residents
#
#  id                     :bigint           not null, primary key
#  active                 :boolean          default(TRUE), not null
#  birthday               :date             default(Mon, 01 Jan 1900), not null
#  can_cook               :boolean          default(TRUE), not null
#  email                  :string
#  multiplier             :integer          default(2), not null
#  name                   :string           not null
#  password_digest        :string           not null
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
#  index_residents_on_email                 (email) UNIQUE
#  index_residents_on_name                  (name) UNIQUE
#  index_residents_on_reset_password_token  (reset_password_token) UNIQUE
#  index_residents_on_unit_id               (unit_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (unit_id => units.id)
#

class Resident < ApplicationRecord
  # Ransack allowlists for ActiveAdmin filtering and sorting.
  # Deliberately excludes password_digest and reset_password_token.
  def self.ransackable_attributes(_auth_object = nil)
    %w[id active birthday can_cook community_id created_at email multiplier name unit_id updated_at vegetarian]
  end

  attr_reader :password

  scope :adult, -> { where('multiplier >= 2') }
  scope :active, -> { where(active: true) }

  belongs_to :community
  belongs_to :unit

  has_one :key, as: :identity, autosave: true, dependent: :destroy
  has_one :resident_balance, dependent: :destroy
  has_many :bills, dependent: :destroy
  has_many :meal_residents, dependent: :destroy
  has_many :meals, through: :meal_residents
  has_many :guests, dependent: :destroy
  has_many :reconciliation_balances, dependent: :destroy
  has_many :guest_room_reservations, dependent: :destroy
  has_many :common_house_reservations, dependent: :destroy

  validates :multiplier, numericality: { only_integer: true }
  validates :name, presence: true, uniqueness: { case_sensitive: false }

  VALID_EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
  validates :email, presence: true, length: { maximum: 255 },
                    format: { with: VALID_EMAIL_REGEX },
                    uniqueness: { case_sensitive: false }, allow_nil: true
  validate :email_presence

  before_validation :set_email
  before_save { self.email = email.downcase unless email.nil? }
  before_save :update_token
  after_commit :invalidate_calendar_cache_if_birthday_changed
  after_commit :notify_residents_update

  # PASSWORD STUFF
  def authenticate(unencrypted_password)
    SCrypt::Password.new(password_digest).is_password?(unencrypted_password) && self
  end

  def password=(unencrypted_password)
    @password = unencrypted_password
    self.password_digest = SCrypt::Password.create(unencrypted_password)
  end

  def update_token
    return unless password_digest_changed?

    if persisted?
      key.set_token
    else
      build_key
    end
  end

  # HELPERS
  def email_presence
    errors.add(:email, 'cannot be blank.') if active && can_cook && multiplier >= 2 && email.nil?
  end

  def set_email
    self.email = nil if email == ''
  end

  def age
    now = Time.zone.today
    had_birthday = now.month > birthday.month ||
                   (now.month == birthday.month && now.day >= birthday.day)
    now.year - birthday.year - (had_birthday ? 0 : 1)
  end

  # DERIVED DATA
  #
  # calc_balance and its helpers (bill_reimbursements, meal_resident_costs,
  # guest_costs) are the per-resident implementation of balance computation.
  # They are NOT used in production — the billing:recalculate rake task has
  # an equivalent batch-optimized implementation that avoids N+1 queries.
  #
  # These methods are kept as a correctness oracle:
  #   - spec/tasks/billing_recalculate_correctness_spec.rb compares the rake
  #     task output against calc_balance to verify both paths agree.
  #   - spec/models/resident_spec.rb tests the individual calculation logic.
  #
  # If you change financial logic in the rake task, update these methods too
  # (and vice versa) — they must stay in sync.

  def calc_balance
    return BigDecimal('0') unless Meal.unreconciled.exists?

    bill_reimbursements - meal_resident_costs - guest_costs
  end

  def bill_reimbursements
    relevant_bills = bills.joins(:meal).merge(Meal.unreconciled.with_attendees)
                          .where(no_cost: false)
                          .preload(meal: %i[bills meal_residents guests])

    relevant_bills.sum(BigDecimal('0')) do |bill|
      meal = bill.meal
      total_cost = meal.bills.reject(&:no_cost).sum(BigDecimal('0'), &:amount)
      next BigDecimal('0') if total_cost.zero?

      next bill.amount unless meal.capped?

      total_mult = meal.meal_residents.sum(&:multiplier) + meal.guests.sum(&:multiplier)
      max_cost = meal.cap * total_mult
      if total_cost > max_cost
        (bill.amount / total_cost) * max_cost
      else
        bill.amount
      end
    end
  end

  def meal_resident_costs
    meal_residents.joins(:meal).merge(Meal.unreconciled).sum(&:cost)
  end

  def guest_costs
    guests.joins(:meal).merge(Meal.unreconciled).sum(&:cost)
  end

  # Balance is read from the cached resident_balances table (unreconciled preview).
  # The daily billing:recalculate rake task refreshes this value.
  def balance
    resident_balance&.amount || BigDecimal('0')
  end

  # Historical balance for a specific reconciliation period.
  def balance_for_reconciliation(reconciliation)
    reconciliation_balances.find_by(reconciliation_id: reconciliation.id)&.amount || BigDecimal('0')
  end

  def meals_attended
    return 0 if Meal.unreconciled.none?

    meal_residents.joins(:meal).where({ meals: { reconciliation_id: nil } }).count
  end

  private

  def invalidate_calendar_cache_if_birthday_changed
    return unless saved_change_to_birthday?

    # Birthdays appear on the calendar. See CalendarSerializer for the full
    # cache invalidation contract. Invalidate both the old and new month
    # (if birthday moved from March to April, both months need refreshing).
    old_birthday = birthday_before_last_save
    if old_birthday.present?
      old_date = Date.new(Time.zone.today.year, old_birthday.month, 1)
      community.invalidate_calendar_cache(old_date)
    end

    # Invalidate the new month
    new_date = Date.new(Time.zone.today.year, birthday.month, 1)
    community.invalidate_calendar_cache(new_date)
  end

  # Columns that the /api/v1/communities/:id/hosts query depends on. A change
  # to any of these can alter whether a resident appears in the list or how
  # they render. The query filters by `active` + `multiplier >= 2` and plucks
  # `residents.name` and `units.name` (via `unit_id` join). Keep in sync with
  # CommunitiesController#hosts.
  HOSTS_QUERY_COLUMNS = %w[active multiplier name unit_id].freeze
  private_constant :HOSTS_QUERY_COLUMNS

  # Notify connected clients that the community hosts list may have changed.
  # The frontend caches the hosts list in its MobX store for use by the
  # reservation New/Edit modals; this push lets it refresh the cache in real
  # time so no modal ever shows stale host data.
  def notify_residents_update
    # On create, saved_changes includes every column we set (name/email/unit_id
    # at minimum), so the column intersection already covers the create path —
    # no need for a separate previously_new_record? branch. Destroy leaves
    # saved_changes empty, so gate it explicitly.
    return unless destroyed? || saved_changes.keys.intersect?(HOSTS_QUERY_COLUMNS)

    Pusher.trigger(
      "community-#{community_id}-residents",
      'update',
      { message: 'residents updated' }
    )
  rescue StandardError => e
    # Never let a Pusher outage break a resident save. Frontend falls back
    # to silent refetch on reconnect (see DataStore#refetchHostsSilently).
    Rails.logger.warn("Pusher.trigger failed in notify_residents_update: #{e.class}: #{e.message}")
    nil
  end
end
