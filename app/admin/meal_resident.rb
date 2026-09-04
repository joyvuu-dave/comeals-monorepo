# typed: false
# frozen_string_literal: true

# Attendance corrections (issue #25). One row per change, through normal
# ActiveRecord create/destroy, so every model guard and audit hook runs.
# The admin_correction flag lifts only the closed-meal freeze —
# ReconciledMealImmutability still refuses, and its error surfaces as the
# redirect alert. No index or forms: the meal's show page is the UI.
ActiveAdmin.register MealResident do
  belongs_to :meal
  actions :create, :destroy

  controller do
    # ActiveAdmin authorizes inside `resource` and `build_resource`
    # (ResourceController::DataAccess). The actions below are hand-written and
    # call neither — they load the meal and build the row directly — so the
    # authorization adapter was never consulted on this path. Attendance
    # drives the cost split, so correcting it is a money write and needs a
    # superuser (ADR 0004). Without this before_action any signed-in admin
    # could add or remove attendance on a closed meal.
    before_action :authorize_attendance_correction!

    def create
      meal = Meal.find(params[:meal_id])
      row = meal.meal_residents.new(
        resident_id: params.require(:meal_resident).permit(:resident_id)[:resident_id]
      )
      row.admin_correction = true
      if row.save
        redirect_to admin_meal_path(meal), notice: "Added #{row.resident.name} to the meal."
      else
        redirect_to admin_meal_path(meal), alert: row.errors.full_messages.to_sentence
      end
    end

    def destroy
      meal = Meal.find(params[:meal_id])
      row = meal.meal_residents.find(params[:id])
      row.admin_correction = true
      if row.destroy
        redirect_to admin_meal_path(meal), notice: "Removed #{row.resident.name} from the meal."
      else
        redirect_to admin_meal_path(meal), alert: row.errors.full_messages.to_sentence
      end
    end

    private

    # Authorizes against the MealResident class rather than a built row: the
    # decision is per resource, and building the row first would run model
    # callbacks before deciding whether the actor may write at all.
    def authorize_attendance_correction!
      authorize!(action_name.to_sym, MealResident)
    end
  end
end
