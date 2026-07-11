# frozen_string_literal: true

require 'rails_helper'

# Renders every page (index, show, new, edit) of every registered ActiveAdmin
# resource against a real record. ActiveAdmin breaks quietly: renaming a model
# method passes every model spec, then 500s the admin page that uses it the
# next time an admin opens it. Rendering each page here catches that.
#
# ADMIN_PAGE_RESOURCES is an explicit table. The two registry examples
# compare it against what ActiveAdmin actually has registered, so this
# spec fails with instructions when a resource is added or its actions
# change.
ADMIN_PAGE_ACTIONS = %i[index show new edit].freeze

# Pages each resource serves, plus a builder for one persisted record.
# The record is created before every page, including index, so index
# column blocks run against at least one row. MealResident serves no
# pages: it allows only :create and :destroy (per-row attendance
# corrections nested under Meal).
ADMIN_PAGE_RESOURCES = {
  'AdminUser' => {
    pages: %i[index show new edit],
    record: -> { admin_user }
  },
  'Bill' => {
    pages: %i[index show new edit],
    record: -> { create(:bill, meal: meal, resident: resident, community: community) }
  },
  'CommonHouseReservation' => {
    pages: %i[index show new edit],
    record: -> { create(:common_house_reservation, community: community, resident: resident) }
  },
  'Community' => {
    pages: %i[index show new edit],
    record: -> { community }
  },
  'Event' => {
    pages: %i[index show new edit],
    record: -> { create(:event, community: community) }
  },
  'GuestRoomReservation' => {
    pages: %i[index show new edit],
    record: -> { create(:guest_room_reservation, community: community, resident: resident) }
  },
  'Meal' => {
    pages: %i[index show new edit],
    record: -> { meal }
  },
  'MealResident' => {
    pages: []
  },
  'Reconciliation' => {
    pages: %i[index show new],
    record: -> { create(:reconciliation, community: community) }
  },
  'Resident' => {
    pages: %i[index show new edit],
    record: -> { resident }
  },
  'Rotation' => {
    pages: %i[index show new edit],
    record: -> { create(:rotation, community: community) }
  },
  'Unit' => {
    pages: %i[index show new edit],
    record: -> { unit }
  }
}.freeze

RSpec.describe 'Admin pages' do
  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit) }
  let(:meal) { create(:meal, community: community) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  # Resources register lazily, so force the load. ActiveAdmin also registers
  # its own Comment resource; this spec covers only what app/admin defines.
  def registered_admin_resources
    ActiveAdmin.application.load!
    ActiveAdmin.application.namespaces
               .flat_map { |ns| ns.resources.grep(ActiveAdmin::Resource) }
               .reject { |r| r.resource_class.name.start_with?('ActiveAdmin::') }
  end

  ADMIN_PAGE_RESOURCES.each do |model, config|
    config[:pages].each do |page|
      it "renders #{model} #{page}" do
        record = instance_exec(&config[:record])
        base = "/#{model.underscore.pluralize}"
        path =
          case page
          when :index then base
          when :new   then "#{base}/new"
          when :show  then "#{base}/#{record.id}"
          when :edit  then "#{base}/#{record.id}/edit"
          end
        get path
        expect(response).to have_http_status(:ok), "GET #{path} returned #{response.status}"
        expect(response.body).to include('id="active_admin_content"')
      end
    end
  end

  it 'has a table row for every registered ActiveAdmin resource' do
    registered = registered_admin_resources.map { |r| r.resource_class.name }
    expect(registered.sort).to eq(ADMIN_PAGE_RESOURCES.keys.sort),
                               'app/admin changed — update the resources table in this spec.'
  end

  it 'declares exactly the pages each resource serves' do
    registered_admin_resources.each do |aa_resource|
      model = aa_resource.resource_class.name
      served = (aa_resource.defined_actions & ADMIN_PAGE_ACTIONS).sort
      declared = ADMIN_PAGE_RESOURCES.fetch(model, { pages: [] })[:pages].sort
      expect(declared).to eq(served),
                          "#{model} serves #{served.inspect} but this spec's table declares " \
                          "#{declared.inspect} — update the table."
    end
  end
end
