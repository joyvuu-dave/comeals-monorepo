# frozen_string_literal: true

# When the app runs at SERIALIZABLE, PostgreSQL can refuse any transaction for
# a conflict. The API answers that with a 409 and a message, after
# RetryOnConflict has tried three times (Api::V1::MealsController). Admin gets
# the message but no automatic retry. Without this, a conflict in admin is an
# uncaught exception and a 500.
#
# Why no retry here. ActiveAdmin memoizes the row it read into @meal, @bill and
# so on, inside `resource` and `build_resource`
# (ActiveAdmin::ResourceController::DataAccess). Those run before any code we
# write, so a retry in the same controller instance reuses the row the failed
# attempt read. It would write again from the read the database just refused,
# which is the opposite of retrying — a retry has to re-read. Clearing those
# instance variables by hand would work only for as long as the gem keeps using
# the same names, and would fail quietly after an upgrade.
#
# So the person retries instead, by submitting the form again. That is
# acceptable in admin and not in the API: admin has one person using it at a
# time, so the conflict is rare, and re-submitting is one click. It is also the
# same thing the shared screen already does — it reverts the change, shows the
# message, and the person taps again.
#
# Nothing is written when a transaction is refused, and nothing outside the
# database happens either. No admin path sends mail. Meal, Bill, MealResident
# and Guest send their Pusher event from an after_action in
# Api::V1::MealsController, so admin never sends one. Event, Rotation,
# CommonHouseReservation and GuestRoomReservation send theirs from
# after_commit, which does not run on a rollback. So the message can tell the
# person nothing was saved, and that is true.
#
# TransactionRollbackError, not SerializationFailure, so this covers a deadlock
# too. Both are the same problem with the same answer. This matches what
# Api::V1::MealsController#with_meal_lock rescues.
#
# On ActiveAdmin::BaseController so resource controllers and register_page
# controllers both inherit it. Devise's sign-in controllers inherit from
# Devise, not ActiveAdmin, so a conflict while signing in is still a 500. That
# is a Devise trackable write on a table the money code never touches.
#
# See docs/adr/0005-serializable-by-default.md.
Rails.application.config.to_prepare do
  ActiveAdmin::BaseController.class_eval do
    # rescue_from appends without checking for a duplicate, and this block runs
    # again on every reload in development, because the constant belongs to the
    # gem and the reloader never unloads it. Registering twice would behave the
    # same but grow the list on each reload, so register once.
    unless rescue_handlers.any? { |klass, _| klass == 'ActiveRecord::TransactionRollbackError' }
      rescue_from ActiveRecord::TransactionRollbackError, with: :redirect_after_conflict
    end

    private

    # Reported, because there is no retry here to report it. RetryOnConflict
    # reports each attempt it makes; admin makes none, so without this a
    # conflict in admin would show up nowhere.
    def redirect_after_conflict(error)
      Rails.error.report(
        error,
        handled: true,
        severity: :warning,
        context: { controller: controller_name, action: action_name }
      )

      redirect_back_or_to admin_root_path,
                          alert: 'Someone else was changing this at the same time. ' \
                                 'Nothing was saved. Try again.'
    end
  end
end
