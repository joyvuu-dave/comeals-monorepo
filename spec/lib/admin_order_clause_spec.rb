# frozen_string_literal: true

require 'rails_helper'

# The rule for ?order= on every admin index, checked against the pages
# app/admin really registers. The requests themselves, with the downloads
# and the read-only token, are in spec/requests/admin/sort_order_spec.rb.
RSpec.describe AdminOrderClause do
  # Every admin page with an index, which is the only action that sorts.
  # MealResident has none (it only adds and removes one row), and
  # ActiveAdmin also registers its own Comment model, which this app does
  # not use (config.comments = false).
  def admin_resources
    ActiveAdmin.application.load!
    ActiveAdmin.application.namespaces[:admin].resources.grep(ActiveAdmin::Resource).select do |resource|
      resource.resource_class < ApplicationRecord && resource.defined_actions.include?(:index)
    end
  end

  def resource_for(model)
    admin_resources.find { |resource| resource.resource_class == model }
  end

  def refused_columns(resource)
    resource.resource_column_names - resource.resource_class.ransortable_attributes
  end

  it 'sorts every admin page' do
    expect(admin_resources.map { |resource| resource.resource_class.name }).to include('AdminUser', 'Bill', 'Resident')
    expect(admin_resources.map(&:order_clause).uniq).to eq([described_class])
  end

  it 'allows the default order of every admin page' do
    admin_resources.each do |resource|
      expect(described_class.new(resource, resource.sort_order).valid?).to be(true),
                                                                           "#{resource.resource_class.name} sorts by " \
                                                                           "#{resource.sort_order} by default, " \
                                                                           'which it does not allow'
    end
  end

  it 'uses the default order for every column a model does not list, on every admin page' do
    expect(refused_columns(resource_for(Resident))).to include('password_digest', 'reset_password_token',
                                                               'reset_password_sent_at', 'keys_valid_since')

    admin_resources.each do |resource|
      default = described_class.new(resource, resource.sort_order)
      refused_columns(resource).each do |column|
        clause = described_class.new(resource, "#{column}_asc")

        expect([clause.field, clause.order, clause.sql]).to eq([default.field, default.order, default.sql]),
                                                            "#{resource.resource_class.name} can be sorted by #{column}"
      end
    end
  end

  it 'writes an allowed column with its table name, in the direction asked for' do
    resident_page = resource_for(Resident)

    expect(described_class.new(resident_page, 'name_desc').sql).to eq('"residents"."name" desc')
    expect(described_class.new(resident_page, 'email_asc').sql).to eq('"residents"."email" asc')
    expect(described_class.new(resident_page, 'email_asc').valid?).to be(true)
  end

  it 'uses the SQL of the page\'s order_by block for a key on a joined table' do
    bills_page = resource_for(Bill)

    expect(described_class.new(bills_page, 'residents.name_asc').sql).to eq('residents.name asc')
    expect(described_class.new(bills_page, 'units.name_desc').sql).to eq('units.name desc')
    expect(described_class.new(bills_page, 'units.name_desc').valid?).to be(true)
  end

  # meals.date desc is the bills page's default.
  it 'uses the default order for a column of a joined table that the page did not declare' do
    bills_page = resource_for(Bill)

    expect(described_class.new(bills_page, 'residents.password_digest_asc').sql).to eq('meals.date desc')
    expect(described_class.new(bills_page, 'admin_users.encrypted_password_asc').sql).to eq('meals.date desc')
  end

  it 'uses the default order for a key with an operator after an allowed column' do
    expect(described_class.new(resource_for(Resident), "name->'x'_desc").sql).to eq('"residents"."name" asc')
    expect(described_class.new(resource_for(Bill), "meals.date->'x'_asc").sql).to eq('meals.date desc')
  end

  it 'uses the default order for a key with no direction, and for no key' do
    resident_page = resource_for(Resident)

    expect(described_class.new(resident_page, 'email').sql).to eq('"residents"."name" asc')
    expect(described_class.new(resident_page, nil).sql).to eq('"residents"."name" asc')
  end

  # So a page whose default names a column the model does not list gets no
  # ORDER BY from ActiveAdmin, instead of a sort by that column.
  it 'is not valid when the page\'s own default is not allowed either' do
    resident_page = resource_for(Resident)
    allow(resident_page).to receive(:sort_order).and_return('password_digest_asc')

    expect(described_class.new(resident_page, 'password_digest_asc').valid?).to be(false)
    expect(described_class.new(resident_page, 'reset_password_token_desc').valid?).to be(false)
  end
end
