# frozen_string_literal: true

# Data-quality warnings for a settlement preview: things that are allowed,
# and settle fine, but usually mean someone forgot a step. The reconciler
# reads them before committing. Nothing here changes the arithmetic.
#
# Each warning is a hash the API sends as is. `id` is deterministic
# (kind:meal=N[:bill=N]) so a client can diff two previews; `kind` is a
# string a client may switch on; `title` and `body` are the words a client
# shows, so wording changes here and nowhere else. A client must render a
# kind it does not know by its title and body, which is how new kinds get
# added without a client release.
#
# Two inputs, because the most important warning is about meals that are
# NOT in the settlement. `meals` are the ones the settlement would claim;
# `skipped` are the ones it would leave behind because people ate and no
# cook billed (Settlement::Preview#skipped_meals). A warning's meal_id can
# therefore name a meal that is not in the preview's meal list.
#
# The meals must come with bills (and their residents), meal_residents,
# and guests preloaded — Settlement.preview does that.
class ReconciliationWarnings
  include ActionView::Helpers::NumberHelper

  KINDS = %w[bill_with_no_attendees attendance_without_bill zero_bill_not_flagged].freeze

  def self.for(meals, skipped: [])
    new(meals, skipped: skipped).call
  end

  def initialize(meals, skipped: [])
    @meals = meals
    @skipped = skipped
  end

  def call
    @skipped.map { |meal| attendance_without_bill(meal) } +
      @meals.flat_map { |meal| warnings_for(meal) }
  end

  private

  def warnings_for(meal)
    attendees = meal.meal_residents.size + meal.guests.size
    real_bills = meal.bills.reject(&:no_cost)

    warnings = []
    real_bills.each { |bill| warnings << bill_with_no_attendees(meal, bill) } if attendees.zero?
    real_bills.select { |bill| bill.amount.zero? }.each { |bill| warnings << zero_bill_not_flagged(meal, bill) }
    warnings
  end

  # A cook spent money on a meal nobody ate. The cook absorbs it: no line
  # is written, so the bill is lost unless someone adds the attendance.
  def bill_with_no_attendees(meal, bill)
    warning('bill_with_no_attendees', meal, bill,
            severity: 'warning',
            title: 'Bill with no attendees',
            body: "#{bill.resident.name} submitted a #{money(bill.amount)} bill for a meal with zero attendees.")
  end

  # People ate but no cook entered a receipt. A settlement never claims a
  # meal without a bill, so this meal is left behind and nobody who ate is
  # charged, until someone enters a bill.
  def attendance_without_bill(meal)
    attendees = meal.meal_residents.size + meal.guests.size
    warning('attendance_without_bill', meal, nil,
            severity: 'warning',
            title: 'Attendance without bill',
            body: "#{attendees} #{'person'.pluralize(attendees)} signed up to eat on #{meal.date.iso8601}, " \
                  'but no bill was submitted. This meal will not be settled until a cook enters a bill.')
  end

  # A $0 bill is probably a no-cost meal that was not marked as one.
  def zero_bill_not_flagged(meal, bill)
    warning('zero_bill_not_flagged', meal, bill,
            severity: 'info',
            title: "Bill of $0 not flagged as 'no cost'",
            body: "#{bill.resident.name} submitted a #{money(bill.amount)} bill but didn't mark it as a no-cost meal.")
  end

  def warning(kind, meal, bill, words)
    id = "#{kind}:meal=#{meal.id}"
    id += ":bill=#{bill.id}" if bill
    { id: id, kind: kind, severity: words[:severity], meal_id: meal.id, title: words[:title], body: words[:body] }
  end

  def money(amount)
    number_to_currency(amount)
  end
end
