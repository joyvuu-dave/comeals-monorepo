# frozen_string_literal: true

# The nightly residents:set_multiplier task used hardcoded ages: under 5
# eats free, 5-11 half price, 12 and up full price. These two columns move
# the ages onto the community record so an admin can change them. The
# defaults reproduce the old hardcoded behavior exactly.
#
# The CHECK constraints mirror the Community model validations for writes
# that skip the model (update_all, rake tasks, psql — see CLAUDE.md).
class AddChildPricingAgesToCommunities < ActiveRecord::Migration[8.1]
  def change
    add_column :communities, :free_below_age, :integer, null: false, default: 5
    add_column :communities, :full_price_age, :integer, null: false, default: 12

    # safety_assured: strong_migrations wants new CHECKs added unvalidated to
    # avoid a long lock on a big table. communities has one row, so
    # validation is instant.
    safety_assured do
      add_check_constraint :communities, 'free_below_age >= 0 AND full_price_age >= 0',
                           name: 'communities_child_ages_non_negative'
      add_check_constraint :communities, 'free_below_age <= full_price_age',
                           name: 'communities_child_ages_ordered'
    end
  end
end
