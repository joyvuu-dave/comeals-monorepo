# typed: true
# frozen_string_literal: true

# Which keys an admin index may be sorted by.
#
# ActiveAdmin turns ?order=<key>_<asc|desc> into an ORDER BY. Its own
# OrderClause checks only the shape of the parameter: it accepts any column
# of the table, and it puts a key with a dot in it into the SQL as written.
# This class allows two kinds of key:
#
#   - a column the model lists in ransortable_attributes. That is Ransack's
#     list of sortable columns, and it is ransackable_attributes unless a
#     model says otherwise, so one hand-written list per model decides what
#     can be filtered and what can be sorted.
#   - a key the admin page declares with order_by, like the bills page's
#     meals.date. The block the page gives writes the SQL, so the key from
#     the URL never becomes SQL itself.
#
# Any other key, and a key with an operator after the column, is replaced
# by the page's default order (config.sort_order), so the page looks the
# same as it does when no order was asked for. The default is checked too:
# if a page's default were not allowed, valid? would be false, and
# ActiveAdmin would add no ORDER BY at all.
#
# spec/lib/admin_order_clause_spec.rb checks every admin page against its
# model's columns; spec/requests/admin/sort_order_spec.rb checks the
# downloads and the read-only token.
class AdminOrderClause < ActiveAdmin::OrderClause
  def initialize(active_admin_config, clause)
    super
    return if allowed?

    super(active_admin_config, active_admin_config.sort_order)
  end

  # ActiveAdmin's own valid? asks only that the key had a column and a
  # direction. An allowed key always has both, so this is the whole test.
  def valid?
    allowed?
  end

  private

  def allowed?
    sortable_keys.include?(field)
  end

  def sortable_keys
    active_admin_config.resource_class.ransortable_attributes + active_admin_config.ordering.keys
  end
end
