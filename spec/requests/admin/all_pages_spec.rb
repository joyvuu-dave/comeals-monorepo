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
#
# `unrendered` lists pages a resource routes but that never render here:
# either they are only reachable in a state this spec cannot be in, or they
# only redirect. They still belong in `pages` — the registry example below
# compares that list against the routed actions.
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
  # Community is a singleton. The new form is only reachable on a fresh
  # deployment with no row yet, and this spec always has one, so opening it
  # here is refused (community_creation_spec.rb covers the refusal and the
  # bootstrap case). The index route stays for the menu and breadcrumbs but
  # only redirects to the show page (community_singleton_spec.rb).
  'Community' => {
    pages: %i[index show new edit],
    unrendered: %i[index new],
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
  # Read-only: rows are written by ledger:verify and nothing else, and both
  # the model and a database trigger refuse every update and delete. The
  # record carries mismatches so the show page renders its "What disagreed"
  # panel, which is the part with real logic in it.
  'LedgerCheckRun' => {
    pages: %i[index show],
    record: -> { create(:ledger_check_run, :with_mismatches) }
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
  # No form: the nightly job creates rotations and assigns their meals.
  # The edit form deleted the rotation's existing meals (#78).
  'Rotation' => {
    pages: %i[index show],
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
    rendered = config[:pages] - config.fetch(:unrendered, [])
    rendered.each do |page|
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

    # Every sortable column header links to ?order=<key>_<asc|desc>.
    # AdminOrderClause replaces a key the page does not allow with the
    # page's default order, so a header whose key is refused would do
    # nothing when clicked. Follow each link and check that the page marks
    # that header as sorted, in that direction.
    next unless rendered.include?(:index)

    it "sorts the #{model} index by each column it offers to sort by" do
      instance_exec(&config[:record])
      path = "/#{model.underscore.pluralize}"
      get path
      keys = sort_keys(response.body).values
      expect(keys).not_to be_empty, "#{path} offers no column to sort by"

      keys.each do |key|
        column, direction = key.match(/\A(.+)_(asc|desc)\z/).captures
        get path, params: { order: key }

        header = sort_keys(response.body).find { |_, linked| linked.sub(/_(asc|desc)\z/, '') == column }&.first
        expect(header&.[]('class')).to include("sorted-#{direction}"), "#{path}?order=#{key} did not sort by it"
      end
    end
  end

  # Each sortable header, with the order key its link asks for.
  def sort_keys(body)
    Nokogiri::HTML(body).css('th.sortable').index_with do |header|
      Rack::Utils.parse_query(URI(header.at_css('a')['href']).query)['order']
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
