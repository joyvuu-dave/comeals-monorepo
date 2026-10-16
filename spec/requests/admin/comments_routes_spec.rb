# frozen_string_literal: true

require 'rails_helper'

# Comments are off (config.comments = false), but ActiveAdmin 3 still
# draws routes for its comments resource, and that controller crashed on
# the missing table (#82). A route ahead of ActiveAdmin's now answers
# these URLs with the plain 404 page.
RSpec.describe 'admin comments routes' do
  before do
    host! 'admin.example.com'
    create(:community)
  end

  it 'answers 404 for the comments index and a comment, signed in or not' do
    get '/comments'
    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("The page you were looking for doesn't exist (404)")

    sign_in create(:admin_user, superuser: true)
    get '/comments'
    expect(response).to have_http_status(:not_found)
    get '/comments/1'
    expect(response).to have_http_status(:not_found)
    post '/comments'
    expect(response).to have_http_status(:not_found)
  end

  # The 404 page is public/404.html as it is, a whole HTML page. The app
  # has no application layout today, so this example adds one for itself:
  # if a later change adds one, the page must still not be put inside it.
  it 'sends the 404 page as it is, with no layout around it' do
    original = ApplicationController.view_paths
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'layouts'))
      File.write(File.join(dir, 'layouts', 'application.html.erb'), "<main>a layout</main>\n<%= yield %>")
      ApplicationController.prepend_view_path(dir)

      get '/comments'

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(Rails.public_path.join('404.html').read)
    ensure
      ApplicationController.view_paths = original
    end
  end
end
