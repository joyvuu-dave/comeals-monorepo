# frozen_string_literal: true

ActiveAdmin.register Rotation do
  # STRONG PARAMS
  permit_params :description, meal_ids: []

  # CONFIG
  config.filters = false

  # ACTIONS
  actions :all

  controller do
    # Deleting a rotation is how a schedule change reaches the calendar
    # early: delete upcoming rotations newest-first and the nightly task
    # recreates them under the current schedule. The model guards refuse
    # anything unsafe; show their reason instead of a silent bounce.
    def destroy
      destroy! do |_success, failure|
        failure.html do
          flash[:alert] = resource.errors.full_messages.to_sentence
          redirect_to collection_path
        end
      end
    end
  end

  # INDEX
  index do
    column :id
    # place_value is the number residents see ("Rotation 5" in the app).
    # It is a position, not an identity: it renumbers when a rotation is
    # created or deleted. Use the id to cross-reference records.
    column 'Rotation #', :place_value
    column :start_date
    column 'Period', :description
    column :meals_count
    column :color

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :id
      row('Rotation #', &:place_value)
      row :start_date
      row('Period', &:description)
      row :meals_count
      row :color
      table_for rotation.meals.order(:date) do
        column 'Meals' do |meal|
          link_to meal.date, admin_meal_path(meal)
        end
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :description, input_html: { value: '' }, as: :hidden
      f.input :meals, as: :check_boxes, collection: Meal.where(rotation_id: nil).order(:date).map { |m|
        [m.date.to_s, m.id]
      }
    end

    f.actions
    f.semantic_errors
  end
end
