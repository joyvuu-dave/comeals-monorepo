# frozen_string_literal: true

require 'rails_helper'

# Community is a singleton, so its admin section has no list page. The index
# route stays — the menu item and the breadcrumbs point at it — but it only
# redirects: to the show page once the row exists, and to the new form on a
# fresh database. See app/admin/community.rb.
RSpec.describe 'Admin community singleton redirect' do
  before { host! 'admin.example.com' }

  describe 'with the Community row present' do
    let!(:community) { create(:community) }

    before { sign_in create(:admin_user, community: community, superuser: true) }

    it 'redirects the index to the show page' do
      get '/communities'

      expect(response).to redirect_to("http://admin.example.com/communities/#{community.id}")
    end
  end

  describe 'with no Community row (fresh deployment)' do
    # Mirrors the bootstrap state: an admin created in `rails c` before the
    # community exists, so community_id is nil.
    let(:bootstrap_admin) do
      AdminUser.create!(email: 'bootstrap@example.com',
                        password: 'password',
                        password_confirmation: 'password',
                        superuser: true)
    end

    before { sign_in bootstrap_admin }

    # The bootstrap guard initializer intercepts this request before the
    # index action runs, and the action's own fallback picks the same
    # target. This example pins the destination, whichever layer sends it.
    it 'redirects the index to the new-community form' do
      get '/communities'

      expect(response).to redirect_to(new_admin_community_path)
    end
  end
end
