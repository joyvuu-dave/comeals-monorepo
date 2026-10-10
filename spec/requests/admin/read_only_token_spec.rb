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

  # ActiveAdmin refuses with a redirect to the dashboard and a flash error
  # (superuser_authorization_spec.rb does the same). Naming the target
  # matters: a token that did not sign in at all is also a redirect, to
  # /login, and must not pass as a refusal.
  def expect_denied
    expect(response).to redirect_to('http://admin.example.com/')
    expect(flash[:error]).to eq('You are not authorized to perform this action.')
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
      create(:meal_resident, meal: meal, resident: eater, community: community)
      settle!(cutoff: Date.yesterday)

      get "/residents/#{eater.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Settlement statement')
      expect(response.body).to include('Attended')
    end

    it 'reads any resident\'s page, not only the emailed one' do
      unit = create(:unit, community: community, name: 'Elm')
      other = create(:resident, community: community, unit: unit, name: 'Someone Else')

      get "/residents/#{other.id}", params: { token: token }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Someone Else')
    end
  end

  describe 'what it cannot reach' do
    it 'cannot enumerate admin accounts' do
      get '/admin_users', params: { token: token }

      expect_denied
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

    # The residents index offers CSV and JSON downloads, and the show page
    # answers .json. None of them may carry the password digest or
    # the reset token: a reset token that is still live is as good as the
    # password. The same rule for admins, and where it is kept:
    # secret_columns_spec.rb.
    it 'cannot download a resident\'s password digest or reset token' do
      unit = create(:unit, community: community)
      ann = create(:resident, community: community, unit: unit, name: 'Ann Adult')
      # No other column holds this date, so finding it means a secret column was sent.
      secret_time = Time.zone.local(2001, 2, 3, 4, 5, 6)
      ann.update_columns(reset_password_token: 'live-reset-token', reset_password_sent_at: secret_time,
                         keys_valid_since: secret_time)

      downloads = %W[/residents.csv /residents.json /residents/#{ann.id}.json].index_with do |path|
        get path, params: { token: token }
        expect(response).to have_http_status(:ok)
        response.body
      end

      expect(downloads.select { |_, body| body.include?('live-reset-token') }.keys).to eq([])
      expect(downloads.select { |_, body| body.include?(ann.password_digest) }.keys).to eq([])
      expect(downloads.select { |_, body| body.include?('2001-02-03') }.keys).to eq([])
      # The downloads are real ones, not refusals.
      expect(downloads.values).to all(include('Ann Adult'))
    end
  end

  # Each write below is one the account behind the token could make if it
  # signed in: the params are valid, so only the token rule refuses them.
  describe 'what it cannot write' do
    it 'cannot create an event, even though the account behind it is a superuser' do
      expect do
        post '/events', params: {
          token: token,
          event: { title: 'Sneaky', start_date: 1.day.from_now, end_date: 1.day.from_now + 2.hours }
        }
      end.not_to change(Event, :count)

      expect_denied
    end

    it 'cannot destroy an event' do
      event = create(:event, community: community)

      expect do
        delete "/events/#{event.id}", params: { token: token }
      end.not_to change(Event, :count)

      expect(Event.exists?(event.id)).to be true
      expect_denied
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

      expect_denied
    end

    # Reconciliation is on the token's read list, so this is the money
    # write a widened token rule would let through first. The meal is one
    # a signed-in superuser would settle.
    it 'cannot create a reconciliation' do
      cook = create(:resident, community: community, unit: create(:unit, community: community))
      meal = create(:meal, community: community, date: 1.day.ago.to_date)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      create(:meal_resident, meal: meal, resident: cook, community: community)

      expect do
        post '/reconciliations', params: {
          token: token,
          reconciliation: { end_date: 1.day.ago.to_date }
        }
      end.not_to change(Reconciliation, :count)

      expect_denied
      expect(meal.reload.reconciliation_id).to be_nil
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

    # A config var set to an empty string must not make an empty token
    # a key. Only a token that is present can match.
    it 'redirects an empty token to sign in, even when the configured token is empty too' do
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return('')

      get '/bills', params: { token: '' }
      expect(response).to redirect_to('/login')
    end
  end
end
