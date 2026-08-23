# frozen_string_literal: true

require 'rails_helper'

# Granting and removing admin access, end to end through ActiveAdmin.
#
# Every example here was a live gap before this spec existed. The superuser
# flag was missing from permit_params, so the form silently dropped it: a
# superuser could not create another superuser, could not promote anyone, and
# got a success response either way. Nothing guarded the last superuser, so
# one click on "Delete" took the community from one superuser to zero.
RSpec.describe 'Admin superuser management' do
  let(:community) { create(:community) }
  let(:me) { create(:admin_user, community: community, superuser: true) }
  # A second superuser so demotion and destroy are about the rule under test,
  # not about the last-superuser guard.
  let!(:spare) { create(:admin_user, community: community, superuser: true) }

  before { host! 'admin.example.com' }

  context 'when signed in as a superuser' do
    before { sign_in me }

    it 'creates another superuser' do
      post '/admin_users', params: {
        admin_user: {
          email: 'fresh@example.com', password: 'password123',
          password_confirmation: 'password123',
          superuser: true
        }
      }

      made = AdminUser.find_by(email: 'fresh@example.com')
      expect(made).to be_present
      expect(made.superuser).to be true
    end

    it 'creates a plain admin when the flag is not set' do
      post '/admin_users', params: {
        admin_user: {
          email: 'plain@example.com', password: 'password123',
          password_confirmation: 'password123',
          superuser: false
        }
      }

      expect(AdminUser.find_by(email: 'plain@example.com').superuser).to be false
    end

    it 'promotes a plain admin' do
      other = create(:admin_user, community: community, superuser: false)

      patch "/admin_users/#{other.id}", params: { admin_user: { superuser: true } }

      expect(other.reload.superuser).to be true
    end

    it 'demotes another superuser' do
      patch "/admin_users/#{spare.id}", params: { admin_user: { superuser: false } }

      expect(spare.reload.superuser).to be false
    end

    it 'refuses to demote itself, and says so' do
      patch "/admin_users/#{me.id}", params: { admin_user: { superuser: false } }

      expect(me.reload.superuser).to be true
      expect(flash[:alert]).to match(/cannot remove your own superuser access/i)
    end

    it 'shows the flag on the index and the show page' do
      get '/admin_users'
      expect(response.body).to match(/superuser/i)

      get "/admin_users/#{spare.id}"
      expect(response.body).to match(/superuser/i)
    end
  end

  context 'when only one superuser is left' do
    before do
      me # created first, so demoting `spare` is not itself the last-superuser case
      spare.update!(superuser: false)
      sign_in me
    end

    it 'refuses to destroy them and the account survives' do
      expect do
        delete "/admin_users/#{me.id}"
      end.not_to change(AdminUser, :count)

      expect(AdminUser.exists?(me.id)).to be true
      expect(AdminUser.where(superuser: true).count).to eq(1)
    end

    it 'never lets the community reach zero superusers through the UI' do
      delete "/admin_users/#{me.id}"
      patch "/admin_users/#{me.id}", params: { admin_user: { superuser: false } }

      expect(AdminUser.where(superuser: true).count).to eq(1)
    end
  end

  context 'when signed in as a plain admin' do
    let(:plain) { create(:admin_user, community: community, superuser: false) }

    before { sign_in plain }

    it 'cannot promote itself' do
      patch "/admin_users/#{plain.id}", params: { admin_user: { superuser: true } }

      expect(plain.reload.superuser).to be false
    end

    it 'cannot create an admin at all' do
      expect do
        post '/admin_users', params: {
          admin_user: {
            email: 'sneaky@example.com', password: 'password123',
            password_confirmation: 'password123',
            superuser: true
          }
        }
      end.not_to change(AdminUser, :count)
    end
  end
end
