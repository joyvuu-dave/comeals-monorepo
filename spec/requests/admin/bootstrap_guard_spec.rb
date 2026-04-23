# frozen_string_literal: true

require 'rails_helper'

# The fresh-deploy bootstrap flow: an operator creates an admin in `rails c`
# on an empty database, logs into ActiveAdmin, and creates the singleton
# Community via the UI. During the window between admin creation and community
# creation:
#
#   - admin_users.community_id is nullable (see migration 20260423170000).
#   - Every ActiveAdmin page except the Community new/create form redirects
#     to new_admin_community_path (see initializer active_admin_bootstrap_guard).
#
# Post-bootstrap the guard must be a no-op — confirmed here to prevent a
# regression that would redirect-loop existing deployments.
RSpec.describe 'Admin bootstrap guard' do
  before { host! 'admin.example.com' }

  describe 'with no Community record yet' do
    # Pristine state: no Community row. Admin is created without community_id,
    # mirroring what `rails c` would produce on a fresh deploy. Must be
    # superuser because SuperuserAdapter gates create/new/edit actions —
    # the bootstrap operator always has superuser permissions.
    let(:bootstrap_admin) do
      AdminUser.create!(email: 'bootstrap@example.com',
                        password: 'password',
                        password_confirmation: 'password',
                        superuser: true)
    end

    before { sign_in bootstrap_admin }

    it 'redirects the dashboard to the new-community form' do
      get '/'

      expect(response).to redirect_to(new_admin_community_path)
      expect(flash[:notice]).to match(/create your community/i)
    end

    it 'redirects /residents to the new-community form' do
      get '/residents'

      expect(response).to redirect_to(new_admin_community_path)
    end

    it 'redirects /bills to the new-community form' do
      get '/bills'

      expect(response).to redirect_to(new_admin_community_path)
    end

    it 'redirects /meals to the new-community form' do
      get '/meals'

      expect(response).to redirect_to(new_admin_community_path)
    end

    it 'exempts /communities/new so the bootstrap form is reachable' do
      expect(Community.count).to eq(0) # bootstrap precondition

      get '/communities/new'

      expect(response).to have_http_status(:ok)
    end

    it 'exempts POST /communities so the form can submit' do
      post '/communities', params: {
        community: {
          name: 'Patches Way',
          slug: 'patches',
          cap: '2.50',
          timezone: 'America/Los_Angeles'
        }
      }

      expect(Community.count).to eq(1)
      expect(response).to redirect_to(admin_community_path(Community.first))
    end

    it 'backfills the orphan admin with community_id on Community creation' do
      admin = bootstrap_admin

      post '/communities', params: {
        community: {
          name: 'Patches Way',
          slug: 'patches',
          cap: '2.50',
          timezone: 'America/Los_Angeles'
        }
      }

      expect(admin.reload.community_id).to eq(Community.first.id)
    end
  end

  describe 'post-bootstrap (Community exists)' do
    # Normal production state: one Community, one admin. The guard must be a
    # no-op — NOT redirecting the dashboard is the critical assertion here
    # (a regression that flipped this would break every existing deployment).
    let!(:community) { create(:community) }
    let(:admin) { create(:admin_user, community: community, superuser: true) }

    before { sign_in admin }

    it 'does not redirect the dashboard' do
      get '/'

      expect(response).to have_http_status(:ok)
    end

    it 'does not redirect /residents' do
      get '/residents'

      expect(response).to have_http_status(:ok)
    end

    it 'does not redirect /communities/new (second-community creation is blocked by the model validation instead)' do
      get '/communities/new'

      expect(response).to have_http_status(:ok)
    end

    it 'blocks a second Community via the enforce_singleton validation (not via the guard)' do
      expect do
        post '/communities', params: {
          community: {
            name: 'Second Community',
            slug: 'second',
            cap: '2.50',
            timezone: 'America/New_York'
          }
        }
      end.not_to change(Community, :count)
    end
  end

  describe 'Devise sign-in paths' do
    # The guard hooks ActiveAdmin::BaseController. Devise's SessionsController
    # inherits from Devise::SessionsController, NOT ActiveAdmin::BaseController,
    # so an un-authenticated admin must still be able to reach the login form
    # in the bootstrap state — otherwise the bootstrap admin can't sign in.

    it 'serves the admin login form even when no Community exists' do
      get '/login'

      expect(response).to have_http_status(:ok)
    end
  end
end
