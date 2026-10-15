# typed: strict
# frozen_string_literal: true

# Marks dinners cancelled, for the button under the dinners nobody
# cooked on the settlement preview (ADR 0011 rule 11). An admin sees a
# list of past dinners that people signed up for and no cook signed up
# for, and says yes. This cancels only the ones that still have no cook
# at that moment. A dinner that changed after the list was shown is left
# alone, and the result says why, so the page can tell the admin: a cook
# signed up, it was cancelled already, or it was settled. A dinner
# deleted in between is counted.
#
# Each change is Meal#cancel!, an ordinary save. So the meal's history
# records it with the admin who said yes (audited reads the admin from
# the controller), the meal's page and calendar are told, and the
# database's rules for a cancelled dinner apply.
#
# The meals are locked first, FOR UPDATE and in id order, like a
# settlement's claim, and their cooks are read after that. Every write
# to a bill locks its meal too (the API, LocksItsMealFirst, and the
# trigger for a write from psql), so a cook added while this runs waits
# for it, and then finds the dinner cancelled. One that committed after
# this transaction began is caught by the database: the cancel here
# fails as a conflict, and RetryOnConflict reads the dinners again.
class DinnerCancelling
  extend T::Sig

  # A listed dinner this did not cancel, and why, in words that finish
  # "Left alone: <date>, because ...".
  class LeftAlone < T::Struct
    const :meal, Meal
    const :reason, String
  end

  class Result < T::Struct
    const :cancelled, T::Array[Meal]
    const :left_alone, T::Array[LeftAlone]
    # Listed dinners that no longer exist.
    const :gone, Integer
  end

  sig { params(meal_ids: T::Array[Integer]).returns(Result) }
  def self.call(meal_ids:)
    RetryOnConflict.call { Meal.transaction { cancel(meal_ids.uniq) } }
  end

  sig { params(meal_ids: T::Array[Integer]).returns(Result) }
  def self.cancel(meal_ids)
    meals = Meal.where(id: meal_ids).order(:id).lock.to_a
    with_a_cook = Bill.where(meal_id: meals.map(&:id)).distinct.pluck(:meal_id).to_set
    cancelled = T.let([], T::Array[Meal])
    left_alone = T.let([], T::Array[LeftAlone])
    meals.each do |meal|
      reason = reason_to_leave(meal, with_a_cook)
      if reason
        left_alone << LeftAlone.new(meal: meal, reason: reason)
      else
        cancelled << meal
      end
    end
    cancelled.each(&:cancel!)
    Result.new(cancelled: cancelled, left_alone: left_alone, gone: meal_ids.size - meals.size)
  end

  sig { params(meal: Meal, with_a_cook: T::Set[Integer]).returns(T.nilable(String)) }
  def self.reason_to_leave(meal, with_a_cook)
    return 'it was settled' if meal.reconciled?
    return 'it was cancelled already' if meal.cancelled?

    'a cook signed up for it' if with_a_cook.include?(T.must(meal.id))
  end
  private_class_method :cancel, :reason_to_leave
end
