# typed: true

# What each concern needs from the model that includes it.
#
# A concern calls methods its includer gets from Rails: a belongs_to
# reader, a column reader, a dirty-tracking method. Sorbet checks the
# module on its own and cannot see them. They are declared here, on the
# module, so the concern type-checks; the including model's generated RBI
# (sorbet/rbi/dsl) defines the real ones. Declaring them in the module's
# Ruby source instead would shadow the Rails-generated methods at runtime,
# because a later `include` sits before Rails' generated modules in the
# ancestor chain.
#
# Keep each list in step with the concern it names. A method removed from
# every includer must be removed here too, or Sorbet keeps accepting it.

module ClosedMealAttendanceFreeze
  sig { returns(T.nilable(Meal)) }
  def meal; end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def created_at; end
end

module ReconciledMealImmutability
  sig { returns(T.nilable(Meal)) }
  def meal; end

  sig { returns(T.nilable(Integer)) }
  def meal_id_in_database; end

  sig { returns(T::Boolean) }
  def will_save_change_to_meal_id?; end
end

module NotesMealLiveUpdate
  sig { returns(T.nilable(Meal)) }
  def meal; end

  sig { returns(T.nilable(Integer)) }
  def meal_id; end
end

module HasPhoneNumber
  sig { returns(T.nilable(String)) }
  def phone; end

  sig { params(value: T.nilable(String)).returns(T.nilable(String)) }
  def phone=(value); end
end

module BelongsToTheCommunity
  sig { returns(T.nilable(Community)) }
  def community; end

  sig { params(value: T.nilable(Community)).returns(T.nilable(Community)) }
  def community=(value); end
end
