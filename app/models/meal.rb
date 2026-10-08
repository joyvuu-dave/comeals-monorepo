# typed: strict
# frozen_string_literal: true

# == Schema Information
#
# Table name: meals
#
#  id                :bigint           not null, primary key
#  cap               :decimal(12, 8)
#  closed            :boolean          default(FALSE), not null
#  closed_at         :datetime
#  date              :date             not null
#  description       :text             default(""), not null
#  max               :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  community_id      :bigint           not null
#  reconciliation_id :bigint
#  rotation_id       :bigint           not null
#
# Indexes
#
#  index_meals_on_date               (date) UNIQUE
#  index_meals_on_reconciliation_id  (reconciliation_id)
#  index_meals_on_rotation_id        (rotation_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#  fk_rails_...  (reconciliation_id => reconciliations.id)
#  fk_rails_...  (rotation_id => rotations.id)
#
class Meal < ApplicationRecord
  extend T::Sig

  include BelongsToTheCommunity

  # Ransack allowlists for ActiveAdmin filtering and sorting
  sig { params(_auth_object: T.untyped).returns(T::Array[String]) }
  def self.ransackable_attributes(_auth_object = nil)
    %w[id cap closed closed_at created_at date description max reconciliation_id rotation_id updated_at]
  end

  # Attributes frozen once the meal is reconciled. Bills and attendance rows
  # carry their own reconciled guards; this protects the meal row itself.
  # cap feeds max_cost, so editing it would rewrite settled charges; date
  # fixes which settlement period the meal belongs to; reconciliation_id is
  # the pointer to the settlement itself (no re-pointing, no un-reconciling).
  # community_id is deliberately absent: Community is a DB-enforced singleton
  # (unique singleton_guard), so there is no other community to move to and
  # belongs_to already rejects nonexistent ids before before_save runs.
  FROZEN_WHEN_RECONCILED = T.let(%w[cap date reconciliation_id].freeze, T::Array[String])

  audited
  has_associated_audits

  scope :unreconciled, -> { where(reconciliation_id: nil) }
  # The meals a settlement with this cutoff sweeps: not yet settled, with at
  # least one bill, on or before the cutoff, from a day that is over, and
  # with either someone to charge or nothing owed. A meal where a cook
  # entered a receipt with money on it and nobody signed up is held back
  # (receipt_and_nobody_ate): settling it would write no lines and freeze
  # the meal, taking the cook's money silently and for good. Until
  # 2026-09-10 it did; three times since 2024, for $22.22. A meal whose
  # cook slots are all $0 or no-cost settles with no effect, as before.
  # Meals on today's date are never swept, whatever the cutoff — their
  # receipts and attendance are not final (issue #3).
  scope :settleable_by, lambda { |cutoff, today: Community.instance.today|
    unreconciled.joins(:bills).where(date: ..cutoff).where(date: ...today)
                .where(anyone_ate.or(a_receipt_with_money.not)).distinct
  }
  scope :open, -> { where(closed: false) }
  scope :closed_with_bills, -> { where(closed: true).joins(:bills).distinct }

  # Meals where at least one person ate (meal_resident or guest).
  # A bill on a meal with no attendees has zero financial impact —
  # the cook absorbs the cost and is not reimbursed — which is why a
  # settlement holds such a meal back when the bill has money on it.
  scope :with_attendees, -> { where(anyone_ate) }

  # Held back from a settlement: a receipt with money on it, and nobody to
  # charge. The preview lists these (ReconciliationWarnings,
  # bill_with_no_attendees) so the reconciler can add the attendance or
  # remove the bill before settling.
  scope :receipt_and_nobody_ate, -> { where(anyone_ate.not).where(a_receipt_with_money) }

  # EXISTS, not JOIN, so a SUM over meals is not multiplied by the rows.
  # Public because a scope's lambda runs on the relation, which cannot
  # reach a private class method.
  sig { returns(Arel::Nodes::Node) }
  def self.anyone_ate
    mr = MealResident.arel_table
    g = Guest.arel_table
    MealResident.where(mr[:meal_id].eq(arel_table[:id])).arel.exists
                .or(Guest.where(g[:meal_id].eq(arel_table[:id])).arel.exists)
  end

  sig { returns(Arel::Nodes::Node) }
  def self.a_receipt_with_money
    bills = Bill.arel_table
    Bill.where(bills[:meal_id].eq(arel_table[:id])).where(no_cost: false).where(bills[:amount].gt(0)).arel.exists
  end

  belongs_to :reconciliation, optional: true
  # Required (#100). The calendar and the rotation emails show each meal
  # in its rotation, and a meal with no rotation once stopped the nightly
  # EnsureRotationsJob. NOT NULL on the column refuses writes that skip
  # the model. The message is in config/locales/en.yml.
  belongs_to :rotation

  # Settlement line items exist only on reconciled meals, which already refuse
  # destroy (the prepended guard below). restrict_with_error is the readable
  # backstop for the same rule, declared before the destroy cascades so the
  # check runs before anything is deleted.
  has_many :meal_charges, dependent: :restrict_with_error

  has_many :bills, inverse_of: :meal, dependent: :destroy
  has_many :cooks, through: :bills, source: :resident, dependent: :destroy
  has_many :meal_residents, inverse_of: :meal, dependent: :destroy
  has_many :guests, inverse_of: :meal, dependent: :destroy
  has_many :hosts, through: :guests, source: :resident, dependent: :destroy
  has_many :attendees, through: :meal_residents, source: :resident, dependent: :destroy

  validates :date, presence: true
  # Checked only when max changes. A closed meal can hold more eaters than
  # its max: the admin attendance page adds a person past the open spots
  # (admin_correction). A write that leaves max alone, like a menu edit, is
  # not about max and is not refused for it (#93). The message has no
  # "Max" of its own: full_messages puts the attribute name in front.
  validates :max,
            numericality: {
              greater_than_or_equal_to: :attendees_count,
              message: "can't be less than current number of attendees."
            },
            allow_nil: true,
            if: :will_save_change_to_max?

  validates :date, uniqueness: true

  # Set by the admin New Meal form and the meal edit form (app/admin/meal.rb),
  # and by nothing else. Never saved, and not a form field.
  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :from_admin_form

  # The two admin forms refuse a date after the last meal of the calendar,
  # which is the end of the last rotation (#143). EnsureRotationsJob starts
  # each new rotation the day after the last meal. With a meal after the
  # end, it would skip every schedule day between the end and that meal,
  # and nothing would ever put a meal on those days.
  #
  # Only those forms: the job, the seeds and the test seeds make the meals
  # after the end, one rotation at a time. A flag, not a validation
  # context: Rails gives a save's context to the nested guests too, and a
  # guest's own `on: :create` checks would then not run.
  validate :date_not_after_the_last_rotation, if: :from_admin_form

  # Reconciled meals are immutable (accounting principle: no edits to a closed
  # ledger). Settlement inputs are frozen; an unreconciled meal can still be
  # reconciled (reconciliation_id nil -> id happens via update_all anyway).
  # Before validation, so a reopen clears max before the max check reads
  # it: a meal over its max can always be reopened (#93).
  before_validation :conditionally_set_max
  before_save :reject_frozen_changes_if_reconciled
  before_save :conditionally_set_closed_at
  before_create :set_cap
  # Both destroy guards are prepended: the has_many declarations above
  # register their dependent cascades first, so without prepend a destroy
  # attempt deletes the meal's bills before the guard aborts. In a request
  # that partial delete rolls back, but inside an enclosing transaction
  # (console, rake task, test transaction) the swallowed inner rollback
  # never reaches the outer transaction and the bills stay deleted.
  # Reconciled is declared second so it runs first — its message wins for
  # meals that are both reconciled and closed.
  before_destroy :reject_destroy_if_closed, prepend: true
  before_destroy :reject_destroy_if_reconciled, prepend: true
  # Every write, from any path, tells the clients (LiveUpdate). Bills,
  # attendance and guests note themselves; `touch: true` on their
  # belongs_to does not run these callbacks.
  after_destroy :note_live_update
  after_save :restamp_attendance_for_new_date, if: :saved_change_to_date?
  after_save :note_live_update

  accepts_nested_attributes_for :guests, allow_destroy: true, reject_if: proc { |attributes|
    attributes['resident_id'].blank?
  }

  # NULL cap means "no cap". No more Float::INFINITY.
  sig { returns(T.nilable(BigDecimal)) }
  def cap
    read_attribute(:cap)
  end

  sig { returns(T::Boolean) }
  def capped?
    cap.present?
  end

  sig { void }
  def set_cap
    self.cap = T.must(community).cap
  end

  sig { void }
  def conditionally_set_max
    self.max = nil if closed == false
  end

  # The end is the latest date in the database. On an edit that is read
  # before the save, so this meal counts at the date it has now: the last
  # meal cannot move later, and it can move to any earlier day. A date
  # that is not changing is never after the end, because it is already in
  # the database. With no meal at all there is no end, and any date is
  # allowed.
  #
  # On :base, not :date: the form lists an error on an attribute with the
  # attribute's name in front ("Date This date is ..."). The sentence is
  # in config/locales/en.yml.
  sig { void }
  def date_not_after_the_last_rotation
    new_date = date
    last_date = T.cast(Meal.maximum(:date), T.nilable(Date))
    return if new_date.nil? || last_date.nil? || new_date <= last_date

    errors.add(:base, :after_the_last_rotation, ends_on: last_date.strftime('%b %-d, %Y'))
  end

  # closed_at is the "extras" boundary (ClosedMealAttendanceFreeze): an
  # attendance row created after it may back out, a row created before
  # it may not. So every closed meal must have one.
  #
  # This also covers a meal created closed. closed_was is false on a new
  # record, not nil: Rails fills a new record's attributes from the
  # column defaults, and closed defaults to false. A reviewer once read
  # closed_was as nil here and reported that Meal.create!(closed: true)
  # left closed_at empty. It does not (spec/models/meal_spec.rb pins it),
  # and the database CHECK meals_closed_at_matches_closed refuses a
  # closed meal without a timestamp from any write path at all.
  sig { void }
  def conditionally_set_closed_at
    self.closed_at = Time.current if closed == true && closed_was == false
    self.closed_at = nil if closed == false && closed_was == true
  end

  # This meal's page and its calendar month are stale. So are the pages
  # of the meals on either side by date when this meal is new, gone, or
  # moved: their next_id and prev_id (MealFormSerializer) point past it.
  # That is how the last meal's "next" arrow wakes up when the nightly
  # job adds the next rotation. Every month that shows this meal's
  # rotation can be stale too (#note_rotation_months).
  sig { void }
  def note_live_update
    LiveUpdate.meal(id)
    LiveUpdate.calendar(date)
    # nil unless the date moved; LiveUpdate.calendar notes nothing for nil.
    old_date = saved_changes.dig('date', 0)
    LiveUpdate.calendar(old_date)
    # nil unless the meal moved to another rotation. No form or task does
    # that; the console can.
    old_rotation_id = saved_changes.dig('rotation_id', 0)

    return unless destroyed? || previously_new_record? || old_date || old_rotation_id

    [date, old_date].compact.each { |day| neighbour_ids(day).each { |neighbour| LiveUpdate.meal(neighbour) } }
    note_rotation_months(old_rotation_id)
  end

  # A rotation's chip on the calendar runs from its first meal to its
  # last (RotationSerializer), and a month shows the chip when one of the
  # rotation's meals is in the month's six weeks. So a meal that is new,
  # deleted, moved, or put in another rotation can change the chip on a
  # month far from its own date: a new meal after a rotation's last meal
  # makes the chip longer on every month that shows the rotation (#144).
  #
  # This notes every day from the first to the last meal the rotation has
  # now, after this write (both rotations, when the meal changed
  # rotation). That covers every month that still shows the rotation. A
  # month that showed it only because of this meal, at its old date or
  # before it was deleted, holds that date, and the LiveUpdate.calendar
  # calls in #note_live_update note it. Community#calendar_cache_version
  # counts the same meals.
  sig { params(old_rotation_id: T.nilable(Integer)).void }
  def note_rotation_months(old_rotation_id)
    # Each date needs a name: unnamed, Postgres calls the MAX column
    # "max", and pick then reads it with the type of meals.max, an
    # integer. old_rotation_id is usually nil, and nil matches no meal:
    # every meal has a rotation.
    first, last = Meal.where(rotation_id: [rotation_id, old_rotation_id])
                      .pick('MIN(meals.date) AS first_meal_date', 'MAX(meals.date) AS last_meal_date')
    LiveUpdate.calendar_range(first, last)
  end

  # The meals just before and just after `day`, other than this one.
  sig { params(day: Date).returns(T::Array[Integer]) }
  def neighbour_ids(day)
    others = Meal.where.not(id: id)
    [
      others.where(date: ...day).order(date: :desc, id: :desc).pick(:id),
      others.where(date: (day + 1)..).order(:date, :id).pick(:id)
    ].compact
  end

  # DERIVED DATA — all computed from source, no cached columns.

  sig { returns(Integer) }
  def multiplier
    if meal_residents.loaded? && guests.loaded?
      meal_residents.sum { |mr| T.must(mr.multiplier) } + guests.sum { |guest| T.must(guest.multiplier) }
    else
      T.cast(meal_residents.sum(:multiplier) + guests.sum(:multiplier), Integer)
    end
  end

  sig { returns(Integer) }
  def attendees_count
    if meal_residents.loaded? && guests.loaded?
      meal_residents.size + guests.size
    else
      meal_residents.count + guests.count
    end
  end

  delegate :count, to: :bills, prefix: true

  # No cost methods here on purpose. What a meal costs is MealLedger's
  # arithmetic; screens read it (or the stored meal_charges of a settled
  # meal) through MealCostSummary. A convenience copy on this model is
  # how the math ended up living in three places (#48).

  # An open meal moved to another date is a meal on a different day, and a
  # price band is the band for the day someone eats: every attendance row
  # takes the band for the new date (Resident#multiplier_on). A settled
  # meal cannot move (FROZEN_WHEN_RECONCILED), so a settled charge never
  # changes. Guests keep theirs: a guest's band is what the admin set.
  #
  # A closed meal is stamped again too. Its freeze refuses a new price for
  # the people who were on it when it closed (ClosedMealAttendanceFreeze),
  # because a person changing a price moves every other eater's share. A
  # move is not that: the band follows the date by rule, and only an admin
  # moves a meal. So each row goes through as an admin correction.
  sig { void }
  def restamp_attendance_for_new_date
    date = T.must(self.date)
    # No includes(:resident): goldiloader loads the batch's residents in
    # one query on its own (spec/requests/admin/meal_move_spec.rb moves six
    # rows under prosopite). A row already at the band writes nothing:
    # update! skips the UPDATE when no attribute changed.
    meal_residents.find_each do |row|
      row.admin_correction = true
      row.update!(multiplier: T.must(row.resident).multiplier_on(date))
    end
  end

  sig { returns(T::Boolean) }
  def reconciled?
    reconciliation_id.present?
  end

  # Guards the meal row itself once settled. Checks the DATABASE value of
  # reconciliation_id, not the in-memory one, so reconciling an unreconciled
  # meal (nil -> id) stays legal at the model layer.
  sig { void }
  def reject_frozen_changes_if_reconciled
    return if reconciliation_id_in_database.nil?

    frozen = changes_to_save.keys & FROZEN_WHEN_RECONCILED
    return if frozen.empty?

    errors.add(:base, "Meal has been reconciled. #{frozen.to_sentence} cannot change.")
    throw(:abort)
  end

  # Destroying a settled meal would erase settled source data (and cascade
  # into its bills and attendance rows). Corrections happen as new entries.
  sig { void }
  def reject_destroy_if_reconciled
    return unless reconciled?

    errors.add(:base, 'Meal has been reconciled.')
    throw(:abort)
  end

  # A closed meal's attendance is frozen (ClosedMealAttendanceFreeze), so its
  # destroy could never complete anyway — the cascade would abort on the
  # first frozen row. Refuse up front with a clear reason instead. To delete
  # a closed meal that never happened, reopen it first — two deliberate steps.
  sig { void }
  def reject_destroy_if_closed
    return unless closed?

    errors.add(:base, 'Meal has been closed. Reopen it before deleting.')
    throw(:abort)
  end

  sig { returns(T::Array[Audited::Audit]) }
  def total_audits
    # Newest first; two audits written in the same instant keep id order.
    (associated_audits + audits).sort_by { |audit| [audit.created_at, audit.id] }.reverse
  end

  # HELPERS
  sig { returns(T::Boolean) }
  def another_meal_in_this_rotation_has_less_than_two_cooks?
    Meal.where(rotation_id: rotation_id).where.not(id: id)
        .left_joins(:bills)
        .group(:id)
        .having('COUNT(bills.id) < 2')
        .exists?
  end
end
