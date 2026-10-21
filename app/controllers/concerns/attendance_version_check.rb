# typed: true
# frozen_string_literal: true

# The check of the attendance_version that the meal page sends with each
# write to one person's attendance on a meal: a sign-up (POST), a
# take-off (DELETE), and a Late or Veg change (PATCH), at
# /api/v1/meals/:meal_id/residents/:resident_id (attendance_write). And
# the versions the meal form shows (read_attendance_versions). Included
# in Api::V1::MealsController, which holds the three actions; what it
# provides (meal, render_refused, render_write_under_lock) is declared in
# sorbet/rbi/shims/concerns.rbi.
module AttendanceVersionCheck
  extend ActiveSupport::Concern
  extend T::Sig

  # Rendering, as in the controller: what an action hands to render.
  Rendering = T.type_alias { T::Hash[Symbol, T.untyped] }

  # The answer to an attendance write built on an old version
  # (attendance_write). The page shows it after the person's name.
  STALE_ATTENDANCE = T.let('This sign-up changed after the page showed it, so nothing was saved. ' \
                           'Check it and tap again if needed.', String)
  private_constant :STALE_ATTENDANCE

  private

  # The versions of the meal's attendance, by resident id, for the
  # meal form. Read before set_meal reads the attendance rows, in
  # another statement: the page is not read in one transaction, and a
  # write can commit between the two reads. Read in this order, a
  # version is never newer than the row the form shows with it. If the
  # write commits in between, the form shows the new row with the old
  # version, and the next tap is refused as stale, and the meal loads
  # again. In the other order, the form could show the old row with
  # the new version: Alice still signed up, with the version after her
  # take-off. Her next tap off would then match the version, find no
  # row, and get a 404, and her screen would still show her signed up.
  sig { void }
  def read_attendance_versions
    @attendance_versions = T.let(AttendanceVersion.by_resident_id(params[:meal_id]),
                                 T.nilable(T::Hash[Integer, Integer]))
  end

  # An attendance write under the meal lock (render_write_under_lock),
  # checked against the attendance_version the request sent.
  #
  # The page sends the version of the person's attendance it expects
  # the server to have before this write: the version the meal form
  # showed, plus one for each of the page's own writes on that row that
  # has no answer yet. Under the lock, in each try, the stored version
  # is read, after the settled check. When it is another number, the
  # request was built on a state the server no longer has: it reached
  # the server after a newer one, or after the page gave up on it and
  # the person tapped again, or someone else changed this person's
  # attendance. Nothing is written, and the answer is a 409 of type
  # "stale". The page then loads the meal again.
  #
  # The state alone ("signed up" or not) is not enough to check: a
  # sign-up held on the network, then a newer sign-up and take-off, and
  # then the held sign-up arrives. It expects "not signed up", and that
  # is what the server has. Its version is older, so it is refused.
  #
  # A request with no attendance_version is not checked, and works as
  # it did before the check existed. That is a page loaded before this
  # release, which keeps working until it is loaded again. For a
  # take-off or a change from such a page, set_meal_resident found the
  # row before the lock, as before. For one that sent a version, the
  # row is read here, after the check, so a request built on an old
  # version gets "stale", not "not found". The block gets the row, or
  # nil.
  sig do
    params(blk: T.proc.params(row: T.nilable(MealResident)).returns(Rendering)).void
  end
  def attendance_write(&blk) # rubocop:disable Naming/BlockForwarding -- the sig above has to name the block
    expected = AttendanceVersionParam.from_params(params)
    return render_refused(expected) if expected.is_a?(String)

    render_write_under_lock do
      next yield(@meal_resident) if expected.nil?

      stored = attendance_version_now
      next stale_attendance_rejection(stored) if stored != expected

      yield meal.meal_residents.find_by(resident_id: params[:resident_id])
    end
  end

  sig { returns(T::Boolean) }
  def attendance_version_sent?
    !params[:attendance_version].nil?
  end

  # The stored version of this person's attendance on this meal. Read
  # inside the write's transaction: after a write, the trigger has
  # already counted it.
  sig { returns(Integer) }
  def attendance_version_now
    AttendanceVersion.of(meal, params[:resident_id].to_i)
  end

  sig { params(stored: Integer).returns(Rendering) }
  def stale_attendance_rejection(stored)
    { json: { message: STALE_ATTENDANCE, type: 'stale', attendance_version: stored }, status: :conflict }
  end

  sig { returns(Rendering) }
  def not_found_rendering
    { json: { message: ApiController::NOT_FOUND }, status: :not_found }
  end
end
