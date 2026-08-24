# frozen_string_literal: true

require 'rails_helper'

# The read-only token in the reconciliation emails. It skips Devise and runs
# the request as AdminUser.find(READ_ONLY_ADMIN_ID).
#
# The rule under test is that the token path is read-only BY CONSTRUCTION —
# it does not depend on the backing account being a plain admin. Before this,
# read-only was a property of that account, so setting READ_ONLY_ADMIN_ID to a
# superuser's id would silently turn every mailed link into a write-capable
# one, with CSRF checking skipped as well. Production has it pointed at a
# plain admin today; nothing made that mandatory.
RSpec.describe 'Read-only admin token' do
  let(:community) { create(:community) }
  let(:token) { 'test-readonly-token' }
  # Deliberately a superuser: this is the configuration that used to be unsafe.
  let(:token_account) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
    allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(token_account.id.to_s)
  end

  describe 'what it can read' do
    it 'reads bills, which is what the reconciliation email links to' do
      get '/bills', params: { token: token }
      expect(response).to have_http_status(:ok)
    end

    it 'reads residents and units, which the collection email links to' do
      get '/residents', params: { token: token }
      expect(response).to have_http_status(:ok)

      get '/units', params: { token: token }
      expect(response).to have_http_status(:ok)
    end

    # Nothing about the ledger is private — attendance and cook costs are
    # already on the community calendar, and a balance is derived from exactly
    # that data. A recipient widening the filter to see everyone's balances is
    # working as intended, not a leak.
    # The statement is the reason the resident page matters to a mailed link:
    # the line items behind "you owe $X", not just the number.
    it 'reads a resident\'s settlement statement' do
      resident_unit = create(:unit, community: community)
      cook = create(:resident, community: community, unit: resident_unit, multiplier: 2)
      eater = create(:resident, community: community, unit: resident_unit, multiplier: 2)
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
      settle!(community, cutoff: Date.yesterday)

      get "/residents/#{eater.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Settlement statement')
      expect(response.body).to include('Attended')
    end

    it 'reads any resident\'s balances, not only the emailed one' do
      unit = create(:unit, community: community, name: 'Elm')
      other = create(:resident, community: community, unit: unit, name: 'Someone Else')

      get "/residents/#{other.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Someone Else')
    end
  end

  describe 'what it cannot reach' do
    def expect_denied
      expect(response).to have_http_status(:redirect)
      expect(AdminUser.where(email: 'sneaky@example.com')).not_to exist
    end

    it 'cannot enumerate admin accounts' do
      get '/admin_users', params: { token: token }

      expect(response).to have_http_status(:redirect)
    end

    it 'cannot read community settings' do
      # The index only redirects to the show page now, but a token must be
      # refused there too — refused means sent to the dashboard, not to the
      # settings. Both checks name the target so a redirect-to-show does not
      # pass as a denial.
      get '/communities', params: { token: token }
      expect(response).to redirect_to('http://admin.example.com/')

      get "/communities/#{community.id}", params: { token: token }
      expect(response).to redirect_to('http://admin.example.com/')
    end
  end

  describe 'what it cannot write' do
    it 'cannot create an event, even though the account behind it is a superuser' do
      expect do
        post '/events', params: {
          token: token,
          event: { title: 'Sneaky', start_date: 1.day.from_now }
        }
      end.not_to change(Event, :count)
    end

    it 'cannot destroy an event' do
      event = create(:event, community: community)

      expect do
        delete "/events/#{event.id}", params: { token: token }
      end.not_to change(Event, :count)

      expect(Event.exists?(event.id)).to be true
    end

    it 'cannot create an admin account' do
      expect do
        post '/admin_users', params: {
          token: token,
          admin_user: {
            email: 'sneaky@example.com', password: 'password123',
            password_confirmation: 'password123',
            superuser: true
          }
        }
      end.not_to change(AdminUser, :count)
    end

    it 'cannot create a reconciliation' do
      expect do
        post '/reconciliations', params: {
          token: token,
          reconciliation: { end_date: 1.day.ago.to_date }
        }
      end.not_to change(Reconciliation, :count)
    end
  end

  # A wrong or absent token must not fall through to some partial access —
  # it should land on the ordinary Devise sign-in.
  describe 'without a valid token' do
    it 'redirects to sign in' do
      get '/bills', params: { token: 'wrong-token' }
      expect(response).to redirect_to('/login')

      get '/bills'
      expect(response).to redirect_to('/login')
    end
  end
end
