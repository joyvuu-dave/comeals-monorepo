# typed: true
# frozen_string_literal: true

# A settled meal refuses every change. A close, a cancel, a description or
# a cap that sends the value the meal already has is no change, so it is
# answered the way the send that saved it was (#280): a phone that lost
# the answer to a close, and sends it again after a settlement, is not
# told that the close was refused. A value that cannot be read is not the
# meal's value, so it still gets the settled words.
#
# Read by both settled checks in Api::V1::MealsController: the one before
# the lock (reject_if_reconciled) and, through same_value_answer, the one
# under it (with_meal_lock's before_settled_check). What it uses from the
# controller (params, meal, action_name, render_write_under_lock) is
# declared in
# sorbet/rbi/shims/concerns.rbi.
module SettledSameValue
  extend ActiveSupport::Concern
  extend T::Sig

  # Rendering, as in the controller: what an action hands to render.
  Rendering = T.type_alias { T::Hash[Symbol, T.untyped] }

  private

  sig { returns(T::Boolean) }
  def sends_what_the_meal_has?
    case action_name
    when 'update_closed' then sent_flag(:closed) == meal.closed
    when 'update_cancelled' then sent_flag(:cancelled) == meal.cancelled?
    when 'update_description' then params[:description] == meal.description
    when 'update_max' then params.key?(:max) && sent_max == meal.max
    else false
    end
  end

  # One write under the meal lock (render_write_under_lock) that is
  # answered with answer, and is answered the same, without writing, when
  # the meal is settled and already has the value sent.
  sig { params(answer: Rendering, write: T.proc.void).void }
  def render_same_value_write(answer, &write) # rubocop:disable Naming/BlockForwarding -- the sig above has to name the block
    render_write_under_lock(before_settled_check: same_value_answer(answer)) do
      yield
      answer
    end
  end

  # A before_settled_check for with_meal_lock: answer, under the lock,
  # when the meal is settled and the request sends what it has.
  sig { params(answer: Rendering).returns(T.proc.returns(T.nilable(Rendering))) }
  def same_value_answer(answer)
    -> { answer if meal.reconciled? && sends_what_the_meal_has? }
  end

  # The true or false a request sends under this name, or nil when it
  # cannot be read.
  sig { params(name: Symbol).returns(T.nilable(T::Boolean)) }
  def sent_flag(name)
    flags = TrueOrFalse.from_params(params, [name], required: true)
    flags.is_a?(String) ? nil : flags[name]
  end

  # The cap a request sends: nil for none (null or ""), a whole number,
  # or :unreadable.
  sig { returns(T.nilable(T.any(Integer, Symbol))) }
  def sent_max
    sent = params[:max]
    return nil if sent.blank?

    T.let(Kernel.Integer(sent.to_s, 10, exception: false), T.nilable(Integer)) || :unreadable
  end
end
