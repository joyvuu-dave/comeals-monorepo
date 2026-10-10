# typed: false
# frozen_string_literal: true

# A check box is never required. Formtastic, which builds ActiveAdmin's
# forms, marks a field with a red "*" when the model has a presence or an
# inclusion check on it. Since de60eb10 every true/false column has an
# inclusion check (TrueOrFalse::MESSAGE), so every check box got the "*":
# Vegetarian, Can cook, Active, Closed, All day, Superuser. But a check box
# always sends a value. Rails puts a hidden field that sends 0 before it, so
# it cannot be left empty, and the "*" only made people wonder what they had
# to fill in. A text field the model requires keeps its "*"
# (spec/requests/admin/check_box_required_mark_spec.rb).
#
# The sidebar filters' true/false menu is ActiveAdmin's own input class
# (ActiveAdmin::Inputs::Filters::BooleanInput), not this one, so this does
# not change it.
module CheckBoxNotRequired
  def required?
    false
  end
end

Formtastic::Inputs::BooleanInput.prepend(CheckBoxNotRequired)
