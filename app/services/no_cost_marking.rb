# typed: strict
# frozen_string_literal: true

# Marks blank cook costs No cost, for the button under the dinners that
# wait on the settlement preview (ADR 0011 rule 4). An admin sees a list
# of blank costs and says yes. This changes only the ones that are still
# blank at that moment. A cost that changed after the list was shown is
# left alone, and the result says why, so the page can tell the admin:
# the cook entered a cost, it was marked No cost already, or its dinner
# was settled or cancelled. A cost deleted in between is counted.
#
# Each change is an ordinary save. So the cost's history records it with
# the admin who said yes (audited reads the admin from the controller),
# the meal's page and calendar are told (NotesMealLiveUpdate), and the
# database's rules for a settled meal still apply.
#
# The meals are locked first, FOR UPDATE and in id order, like a
# settlement's claim. Every write to a cost locks its meal too (the API,
# LocksItsMealFirst, and the trigger for a write from psql), so one that
# starts while this runs waits for it. One that committed after this
# transaction began is caught by the database: the update here fails as
# a conflict, and RetryOnConflict reads the costs again.
class NoCostMarking
  extend T::Sig

  # A listed cost this did not change, and why, in words that finish
  # "Left alone: <date>, <cook>, because ...".
  class LeftAlone < T::Struct
    const :bill, Bill
    const :reason, String
  end

  class Result < T::Struct
    const :marked, T::Array[Bill]
    const :left_alone, T::Array[LeftAlone]
    # Listed costs that no longer exist.
    const :gone, Integer
  end

  sig { params(bill_ids: T::Array[Integer]).returns(Result) }
  def self.call(bill_ids:)
    RetryOnConflict.call { Bill.transaction { mark(bill_ids.uniq) } }
  end

  # The cook and the meal are loaded here, inside the transaction, because
  # the page names each cost from them after the commit, and a read after
  # the commit could fail for a change that is saved
  # (spec/requests/no_query_after_commit_spec.rb).
  sig { params(bill_ids: T::Array[Integer]).returns(Result) }
  def self.mark(bill_ids)
    closed_to_changes = lock_meals(Bill.where(id: bill_ids).distinct.pluck(:meal_id))
    bills = Bill.where(id: bill_ids).order(:id).preload(:meal, :resident).to_a
    marked = T.let([], T::Array[Bill])
    left_alone = T.let([], T::Array[LeftAlone])
    bills.each do |bill|
      reason = reason_to_leave(bill, closed_to_changes)
      if reason
        left_alone << LeftAlone.new(bill: bill, reason: reason)
      else
        marked << bill
      end
    end
    marked.each { |bill| bill.update!(no_cost: true) }
    Result.new(marked: marked, left_alone: left_alone, gone: bill_ids.size - bills.size)
  end

  # Locks the meals and returns, for each one whose costs cannot change,
  # why: it was settled, or cancelled (ADR 0011 rule 11).
  sig { params(meal_ids: T::Array[Integer]).returns(T::Hash[Integer, String]) }
  def self.lock_meals(meal_ids)
    rows = T.let(Meal.where(id: meal_ids).order(:id).lock.pluck(:id, :reconciliation_id, :cancelled_at),
                 T::Array[[Integer, T.nilable(Integer), T.nilable(Time)]])
    rows.each_with_object({}) do |(id, reconciliation_id, cancelled_at), reasons|
      if reconciliation_id
        reasons[id] = 'the dinner was settled'
      elsif cancelled_at
        reasons[id] = 'the dinner was cancelled'
      end
    end
  end

  sig { params(bill: Bill, closed_to_changes: T::Hash[Integer, String]).returns(T.nilable(String)) }
  def self.reason_to_leave(bill, closed_to_changes)
    meal_reason = closed_to_changes[T.must(bill.meal_id)]
    return meal_reason if meal_reason
    return 'it was marked No cost already' if bill.no_cost

    'the cook entered a cost' if T.must(bill.amount).positive?
  end
  private_class_method :mark, :lock_meals, :reason_to_leave
end
