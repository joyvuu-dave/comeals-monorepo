# frozen_string_literal: true

require 'rails_helper'

# The admin page of the Common House login (app/admin/common_house_login.rb).
# Setting the password decides who may act at the shared screen, so only a
# superuser may write it, as with AdminUser (SuperuserAdapter
# GOVERNANCE_MODELS). There is at most one login, so the page works like
# Community's: no list, and no "New" once the row exists.
RSpec.describe 'Admin Common House login' do
  let(:community) { create(:community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:plain_admin) { create(:admin_user, community: community, superuser: false) }
  let(:refused) { 'You are not authorized to perform this action.' }

  before { host! 'admin.example.com' }

  def form(password, confirmation = password)
    { common_house_login: { password: password, password_confirmation: confirmation } }
  end

  describe 'as a superuser, with no login yet' do
    before { sign_in superuser }

    it 'sends the list page to the new form' do
      get '/common_house_logins'

      expect(response).to redirect_to(new_admin_common_house_login_path)
    end

    it 'creates the login' do
      post '/common_house_logins', params: form('a long shared password')

      login = CommonHouseLogin.sole
      expect(response).to redirect_to(admin_common_house_login_path(login))
      expect(login.authenticate('a long shared password')).to eq(login)
    end

    it 'refuses a password that does not match its confirmation, and saves nothing' do
      post '/common_house_logins', params: form('a long shared password', 'a long shared passwort')

      # ActiveAdmin draws a refused form again with 200, as on every admin page.
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('doesn&#39;t match Password')
      expect(CommonHouseLogin.count).to eq(0)
    end

    it 'refuses a short password' do
      post '/common_house_logins', params: form('short')

      expect(response.body).to include('must be at least 8 characters')
      expect(CommonHouseLogin.count).to eq(0)
    end

    # Two admins press Create at the same moment. Both pass the model's
    # check, because neither row is saved yet, and the unique index
    # refuses the second insert. Stubbing exists? makes this request the
    # second one.
    it 'answers a second login made at the same moment with the same sentence, not an error page' do
      create(:common_house_login)
      allow(CommonHouseLogin).to receive(:exists?).and_return(false)

      post '/common_house_logins', params: form('another long password')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('There is already a Common House login. Change its password instead.')
      expect(CommonHouseLogin.count).to eq(1)
    end
  end

  describe 'as a superuser, with the login made' do
    let!(:login) { create(:common_house_login) }

    before { sign_in superuser }

    it 'sends the list page to the login' do
      get '/common_house_logins'

      expect(response).to redirect_to(admin_common_house_login_path(login))
    end

    it 'shows the login without its digest' do
      get "/common_house_logins/#{login.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Password Last Changed')
      expect(response.body).not_to include(login.password_digest)
    end

    it 'has no New button and refuses the new form' do
      get "/common_house_logins/#{login.id}"
      expect(response.body).not_to include(new_admin_common_house_login_path)

      get '/common_house_logins/new'
      expect(flash[:error]).to eq(refused)
    end

    it 'changes the password, and the change signs the screen out' do
      before = login.keys_valid_since

      patch "/common_house_logins/#{login.id}", params: form('a new long password')

      login.reload
      expect(response).to redirect_to(admin_common_house_login_path(login))
      expect(login.authenticate('a new long password')).to eq(login)
      expect(login.authenticate('a long shared password')).to be(false)
      expect(login.keys_valid_since).to be > before
    end

    it 'has no delete route' do
      expect { delete "/common_house_logins/#{login.id}" }.to raise_error(ActionController::RoutingError)
      expect(CommonHouseLogin.exists?(login.id)).to be(true)
    end
  end

  describe 'as a plain admin' do
    let!(:login) { create(:common_house_login) }

    before { sign_in plain_admin }

    it 'may see the page' do
      get "/common_house_logins/#{login.id}"

      expect(response).to have_http_status(:ok)
    end

    it 'may not change the password' do
      patch "/common_house_logins/#{login.id}", params: form('a new long password')

      expect(flash[:error]).to eq(refused)
      expect(login.reload.authenticate('a long shared password')).to eq(login)
    end

    it 'may not create the login' do
      login.delete

      post '/common_house_logins', params: form('a long shared password')

      expect(flash[:error]).to eq(refused)
      expect(CommonHouseLogin.count).to eq(0)
    end
  end

  describe 'with the read-only token' do
    let(:token) { 'test-readonly-token' }
    let!(:login) { create(:common_house_login) }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(superuser.id.to_s)
    end

    it 'may not see the page, because the reconciliation emails never link to it' do
      get "/common_house_logins/#{login.id}", params: { token: token }

      expect(response).not_to have_http_status(:ok)
    end
  end
end
