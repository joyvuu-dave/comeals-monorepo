# typed: false
# frozen_string_literal: true

ActiveAdmin.register_page 'Dashboard' do
  menu priority: 1, label: proc { I18n.t('active_admin.dashboard') }

  # Bootstrap redirect (no Community yet → /communities/new) is handled
  # globally in config/initializers/active_admin_bootstrap_guard.rb so it also
  # covers /residents, /bills, etc. ActiveAdmin is mounted at the root of the
  # admin subdomain, so its paths carry no /admin prefix.

  content title: 'Meal Reconciliation' do
    # Each list is loaded once and the panel header counts the loaded rows.
    # This keeps the header and the list in agreement and avoids a separate
    # COUNT query per panel.
    #
    # Everything reads Community.instance directly: this is a
    # single-community app, so the dashboard's data does not depend on
    # which admin is looking at it — and the read-only token path has no
    # current_admin_user to reach through (ADR 0004).
    community = Community.instance
    columns do
      column do
        units = community.units.order(:name).to_a
        panel "Units - #{units.size}" do
          ul do
            units.map do |unit|
              li link_to(unit.name, admin_unit_path(unit))
            end
          end
        end
      end

      column do
        residents = community.residents.active.order(:name).to_a
        panel "Active Residents - #{residents.size}" do
          ul do
            residents.map do |resident|
              li link_to(resident.name, admin_resident_path(resident))
            end
          end
        end
      end

      column do
        upcoming = community.meals.unreconciled.open.where(date: community.today..).order(date: :desc).to_a
        panel "Upcoming Meals - #{upcoming.size}" do
          ul do
            upcoming.map do |meal|
              li do
                text_node link_to(meal.date, admin_meal_path(meal))
                text_node ' (cancelled)' if meal.cancelled?
              end
            end
          end
        end

        closed = community.meals.unreconciled.closed_with_bills.order(date: :desc).to_a
        panel "Closed Meals People Attended (unreconciled) - #{closed.size}" do
          ul do
            closed.map do |meal|
              li do
                text_node link_to(meal.date, admin_meal_path(meal))
                text_node ' (cancelled)' if meal.cancelled?
              end
            end
          end
        end
      end

      column do
        # Only meals whose costs are final (Community#averaged_meals). The
        # meals left out are counted by reason, so a missing receipt stays
        # in view instead of pulling the average toward $0.
        panel 'Averages' do
          counted = community.averaged_meal_count
          left_out_counts = community.meals_left_out_of_averages
          left_out = {
            cost_not_entered: "waiting for a cook's cost", no_cook: 'with no cook',
            nobody_to_charge: 'where only free eaters ate', cancelled: 'that were cancelled'
          }.filter_map do |reason, words|
            count = left_out_counts.fetch(reason)
            "#{count} #{'meal'.pluralize(count)} #{words}" if count.positive?
          end
          ul do
            li "Cost per adult: #{community.unreconciled_ave_cost}"
            li "Attendees per meal: #{community.unreconciled_ave_number_of_attendees}"
            li "Meals counted: #{counted} (days that are over, not settled yet)"
            li "Left out: #{left_out.any? ? left_out.join(', ') : 'none'}"
          end
        end
      end
    end
  end
end
