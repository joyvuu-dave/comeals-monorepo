# typed: true
# frozen_string_literal: true

# The rotation menu on the admin New Meal form (#100). Every meal belongs
# to a rotation, so a one-off meal made in admin needs one too. Each
# choice names the rotation the way the calendar does ("Rotation 5") and
# gives the dates of its first and last meal, so an admin can tell the
# rotations apart.
#
# Each option also carries those two dates as data attributes. When the
# date on the form changes, a small script in active_admin.js picks the
# one rotation whose dates contain it. When no rotation does (a date
# between two rotations, or after the last one), it leaves the menu
# blank, and the admin must choose: a meal with no rotation is refused.
module RotationChoicesHelper
  # [label, id, data attributes] for each rotation, newest first, in the
  # shape a Formtastic select takes. One query for all of them.
  #
  # The two dates need names of their own. Unnamed, Postgres calls the
  # MAX column "max", and pluck then reads it with the type of
  # meals.max, an integer, and raises on the date.
  #
  # Newest first means by place number, which follows the dates of the
  # meals, not by id. Two rotations have the same place number only when
  # neither has one yet: a new rotation gets its number after its save
  # commits (Rotation#set_place_value). Then the newer id comes first.
  def rotation_choices
    Rotation.left_joins(:meals)
            .group(:id)
            .order(place_value: :desc, id: :desc)
            .pluck(:id, :place_value, 'MIN(meals.date) AS first_meal_date', 'MAX(meals.date) AS last_meal_date')
            .map do |id, place_value, first, last|
      [rotation_choice_label(place_value, first, last), id,
       { 'data-first-date' => first&.iso8601, 'data-last-date' => last&.iso8601 }]
    end
  end

  # "Rotation 5: Feb 2–4, 2027". A rotation can be left with no meals
  # when an admin deletes them all; it is still a rotation a meal can go in.
  def rotation_choice_label(place_value, first, last)
    dates = first.nil? ? 'no meals' : DateRangeDescription.for(first, last)
    "Rotation #{place_value}: #{dates}"
  end
end
