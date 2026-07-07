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
  end
end
