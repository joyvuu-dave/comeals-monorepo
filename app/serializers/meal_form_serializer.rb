# typed: true
# frozen_string_literal: true

# The meal form: GET /api/v1/meals/:meal_id/cooks. One meal, its bills,
# its guests, and the residents (see #residents), each marked with
# whether they are attending this meal.
class MealFormSerializer
  include Alba::Resource

  class BillSerializer
    include Alba::Resource

    attributes :resident_id,
               :amount,
               :no_cost
  end

  # Built with `params: { meal: meal }`: each row needs the meal to say
  # whether this resident is attending it.
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
               :active

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
             :next_id,
             :prev_id

  many :bills, resource: BillSerializer

  attribute :residents do |meal|
    T.bind(self, MealFormSerializer)
    ResidentSerializer.new(residents(meal), params: { meal: meal }).to_h
  end

  many :guests, resource: GuestSerializer

  def reconciled(meal)
    meal.reconciliation_id.present?
  end

  def next_id(meal)
    # Next meal by date, or self if this is the last meal
    Meal.where('date > ? OR (date = ? AND id > ?)', meal.date, meal.date, meal.id)
        .order(:date, :id).pick(:id) || meal.id
  end

  def prev_id(meal)
    # Previous meal by date, or self if this is the first meal
    Meal.where('date < ? OR (date = ? AND id < ?)', meal.date, meal.date, meal.id)
        .order(date: :desc, id: :desc).pick(:id) || meal.id
  end

  # Every active resident (for the sign-up list), plus anyone signed up
  # for this meal, plus anyone who has a bill on it, retired or not. A
  # retired resident has moved out or died. Without the second part, a
  # retired resident would be missing from old meals they ate at. Without
  # the third, a retired cook who did not eat would be missing, and the
  # page can show a bill only when its cook is in this list. A bills save
  # removes the bill of any cook the save leaves out
  # (BillsPayload#write_to), so a missing cook could lose their bill on
  # the next save (#91). That holds for a no-cost bill too: it moves no
  # money, but it records who cooked.
  # The ids come from the sign-ups and bills the meal already holds, not
  # from a new read of those tables. The controller loads them first, in
  # another statement, and the page is not read in one transaction. So a
  # save can commit between the two reads. A new read here could then
  # leave out a cook that `bills` still lists, or a resident that the
  # attending flags still mark as eating.
  # Ordered by :id for the same reason CalendarSerializer orders every
  # collection: without ORDER BY, Postgres may return rows in any order,
  # and this JSON is also captured verbatim as a test fixture
  # (rake test:generate_fixtures), which must be byte-stable.
  def residents(meal)
    Resident.where(active: true)
            .or(Resident.where(id: meal.meal_residents.map(&:resident_id)))
            .or(Resident.where(id: meal.bills.map(&:resident_id)))
            .includes(:unit)
            .order(:id)
  end
end
