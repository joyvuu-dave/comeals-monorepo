# frozen_string_literal: true

require 'rails_helper'

# Admin offers CSV and JSON downloads only (#124). XML never carried any
# data: Rails 5 moved to_xml into a gem this app does not use, so an
# index download held only "#<Resident:0x...>", and a show page's .xml
# was a 500. Now ActiveAdmin refuses .xml on an index or a show page
# before the page runs, the same way it refuses any format a page does
# not offer. The 401 and the <error> body are ActiveAdmin's own answer
# (rescue_active_admin_access_denied).
RSpec.describe 'Admin download formats' do
  let(:community) { create(:community) }
  let(:resident) { create(:resident, community: community, unit: create(:unit, community: community)) }
  let(:refusal) { '<error>You are not authorized to perform this action.</error>' }

  before do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: true)
  end

  # Every index page, so a page that sets its own download links is
  # checked too. Comments are ActiveAdmin's own and are off (#82).
  def index_paths
    ActiveAdmin.application.load!
    ActiveAdmin.application.namespaces[:admin].resources.grep(ActiveAdmin::Resource)
               .reject { |resource| resource.resource_class.name.start_with?('ActiveAdmin::') }
               .select { |resource| resource.defined_actions.include?(:index) }
               .map { |resource| "/#{resource.resource_name.route_key}" }
  end

  # ActiveAdmin draws the download links only under a list with rows.
  it 'offers CSV and JSON under the residents list, and no XML' do
    resident

    get '/residents'

    expect(response.parsed_body.css('.download_links a').map(&:text)).to eq(%w[CSV JSON])
  end

  it 'refuses an XML download of every index page' do
    answers = index_paths.index_with do |path|
      get "#{path}.xml"
      [response.status, response.body]
    end

    expect(answers.keys).to include('/residents', '/meals', '/bills')
    expect(answers.values.uniq).to eq([[401, refusal]])
  end

  it 'refuses .xml on a show page instead of failing with a 500' do
    get "/residents/#{resident.id}.xml"

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).to eq(refusal)
  end

  it 'still serves the CSV and JSON downloads' do
    resident

    get '/residents.csv'
    expect(response).to have_http_status(:ok)
    get '/residents.json'
    expect(response).to have_http_status(:ok)
    get "/residents/#{resident.id}.json"
    expect(response).to have_http_status(:ok)
  end
end
