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

    sign_in create(:admin_user, superuser: true)
    get '/comments'
    expect(response).to have_http_status(:not_found)
    get '/comments/1'
    expect(response).to have_http_status(:not_found)
    post '/comments'
    expect(response).to have_http_status(:not_found)
  end
end
