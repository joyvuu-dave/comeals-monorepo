# typed: true
# frozen_string_literal: true

# The meal form: GET /api/v1/meals/:meal_id/cooks. One meal, its bills,
# its guests, and the residents (see #residents), each marked with
# whether they are attending this meal.
#
# Built with `params: { attendance_versions: }`, the versions of the
# meal's attendance by resident id (AttendanceVersion.by_resident_id).
# The controller reads them before the meal's attendance rows
# (AttendanceVersionCheck#read_attendance_versions says why). Left out,
# they are read here, after the rows; that order is fine for a test or
# the console, not for the page.
class MealFormSerializer
  include Alba::Resource

  class BillSerializer
    include Alba::Resource

    attributes :resident_id,
               :amount,
               :no_cost
  end

  # Built with `params: { meal:, attendance_versions: }`: each row needs
  # the meal to say whether this resident is attending it, and the
  # versions of the meal's attendance (AttendanceVersion.by_resident_id).
  class ResidentSerializer
    include Alba::Resource

    attributes :id,
               :meal_id,
               :name,
               :short_name,
               :attending,
               :attending_at,
               :late,
               :vegetarian,
               :can_cook,
               :active,
               :attendance_version

    def meal_id(_resident)
      meal.id
    end

    def attending(resident)
      meal_resident(resident).present?
    end

    def attending_at(resident)
      meal_resident(resident)&.created_at
    end

    # The list form: the unit prefix tells two residents with the same
    # name apart in dropdowns and tables.
    def name(resident)
      "#{resident.unit.name} - #{resident.name}"
    end

    # The sentence form: confirm questions say "Jane hasn't entered a
    # cost yet", not "102 - Jane hasn't entered a cost yet".
    def short_name(resident)
      resident.name
    end

    # How many writes there have been to this person's attendance on
    # this meal (AttendanceVersion). The page sends it with each sign-up,
    # take-off, Late and Veg tap, so the server can refuse a request built
    # on an older state.
    def attendance_version(resident)
      attendance_versions.fetch(resident.id, AttendanceVersion::NONE)
    end

    def late(resident)
      meal_resident(resident)&.late || false
    end

    def vegetarian(resident)
      attendance = meal_resident(resident)
      attendance ? attendance.vegetarian : resident.vegetarian
    end

    private

    def meal
      params.fetch(:meal)
    end

    def meal_resident(resident)
      meal_residents_by_resident_id[resident.id]
    end

    # Alba builds one serializer instance for the whole residents
    # collection, so this lookup is built once per request. The
    # controller preloads meal.meal_residents, so it is no extra query.
    def meal_residents_by_resident_id
      @meal_residents_by_resident_id ||= meal.meal_residents.index_by(&:resident_id)
    end

    # By resident id, read by the controller before the attendance rows
    # (MealsController#read_attendance_versions says why).
    def attendance_versions
      params.fetch(:attendance_versions)
    end
  end

  class GuestSerializer
    include Alba::Resource

    attributes :id,
               :meal_id,
               :resident_id,
               :vegetarian,
               :created_at
  end

  attributes :id,
             :description,
             :max,
             :closed,
             :closed_at,
             :date,
             :reconciled,
             :cancelled,
             :next_id,
             :prev_id

  many :bills, resource: BillSerializer

  attribute :residents do |meal|
    T.bind(self, MealFormSerializer)
    versions = params.fetch(:attendance_versions) { AttendanceVersion.by_resident_id(meal.id) }
    ResidentSerializer.new(residents(meal), params: { meal: meal, attendance_versions: versions }).to_h
  end

  many :guests, resource: GuestSerializer

  def reconciled(meal)
    meal.reconciliation_id.present?
  end

  # ADR 0011 rule 11. The page freezes the sign-ups, guests and costs of
  # a cancelled dinner, and offers Restore until it is settled.
  def cancelled(meal)
    meal.cancelled?
  end

  # Two meals never share a date (the unique index index_meals_on_date),
  # so the date alone puts them in order.
  def next_id(meal)
    # Next meal by date, or self if this is the last meal
    Meal.where('date > ?', meal.date).order(:date).pick(:id) || meal.id
  end

  def prev_id(meal)
    # Previous meal by date, or self if this is the first meal
    Meal.where(date: ...meal.date).order(date: :desc).pick(:id) || meal.id
  end

  # Every active resident (for the sign-up list), plus anyone signed up
  # for this meal, plus anyone who has a bill on it, plus anyone who has
  # a guest on it, retired or not. A retired resident has moved out or
  # died. Without the second part, a retired resident would be missing
  # from old meals they ate at. Without the third, a retired cook who did
  # not eat would be missing, and the page can show and change a bill
  # only when its cook is in this list. That holds for a no-cost bill
  # too: it moves no money, but it records who cooked. (Before #135 a
  # bills save also removed the bill of any cook it left out, so a
  # missing cook lost their bill on the next save, #91. A save now names
  # only the cooks it changes.) Without the fourth, a retired host who
  # did not eat would be missing (a host can add a guest without signing
  # up). The page shows a guest only in its host's row, so that guest
  # would be counted and charged to the host, but no row would show it,
  # and nobody could remove it from the page (#134).
  # The ids come from the sign-ups, bills and guests the meal already
  # holds, not from a new read of those tables. The controller loads them
  # first, in another statement, and the page is not read in one
  # transaction. So a save can commit between the two reads. A new read
  # here could then leave out a cook that `bills` still lists, a host that
  # `guests` still lists, or a resident that the attending flags still
  # mark as eating.
  # Ordered by :id for the same reason CalendarSerializer orders every
  # collection: without ORDER BY, Postgres may return rows in any order,
  # and this JSON is also captured verbatim as a test fixture
  # (rake test:generate_fixtures), which must be byte-stable.
  def residents(meal)
    Resident.where(active: true)
            .or(Resident.where(id: meal.meal_residents.map(&:resident_id)))
            .or(Resident.where(id: meal.bills.map(&:resident_id)))
            .or(Resident.where(id: meal.guests.map(&:resident_id)))
            .includes(:unit)
            .order(:id)
  end
end
