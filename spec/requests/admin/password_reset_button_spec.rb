# frozen_string_literal: true

require 'rails_helper'

# The admin "Send password reset email" button. It exists for residents who
# cannot work the "forgot password" flow themselves; the admin triggers the
# same email the login page would send. There is deliberately no way for an
# admin to type a new password — that would make the password a secret two
# people know, and would let any admin sign in as any resident.
#
# The permission tier under test: any signed-in admin may send the email
# (same tier as editing the resident), and the read-only token may not.
RSpec.describe 'Admin password reset button' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit, email: 'sarah@example.com') }

  before { host! 'admin.example.com' }

  context 'when signed in as a plain admin' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it 'shows the button on the resident page' do
      get "/residents/#{resident.id}"

      expect(response.body).to include('Send password reset email')
    end

    it 'stamps a token and emails the reset link' do
      expect { post "/residents/#{resident.id}/send_password_reset" }
        .to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(resident.reload.reset_password_token).to be_present
      expect(response).to redirect_to("/residents/#{resident.id}")
      follow_redirect!
      expect(response.body).to include('Password reset link emailed to sarah@example.com')
    end

    context 'with a resident who has no email address' do
      let(:child) do
        create(:resident, community: community, unit: unit, email: nil, multiplier: 1,
                          name: 'Kid Example')
      end

      it 'does not show the button' do
        get "/residents/#{child.id}"

        expect(response.body).not_to include('Send password reset email')
      end

      it 'refuses the post with an explanation and sends nothing' do
        expect { post "/residents/#{child.id}/send_password_reset" }
          .not_to(change { ActionMailer::Base.deliveries.count })

        expect(child.reload.reset_password_token).to be_nil
        follow_redirect!
        expect(response.body).to include('has no email address')
      end
    end

    context 'when the email cannot be delivered' do
      before do
        mail_double = instance_double(ActionMailer::MessageDelivery)
        allow(ResidentMailer).to receive(:password_reset_email).and_return(mail_double)
        allow(mail_double).to receive(:deliver_now).and_raise(Net::ReadTimeout)
      end

      it 'keeps the token and tells the admin the email did not go out' do
        post "/residents/#{resident.id}/send_password_reset"

        expect(resident.reload.reset_password_token).to be_present
        follow_redirect!
        expect(response.body).to include('the email could not be sent')
      end
    end
  end

  # The mailed read-only links must not be able to trigger email to residents.
  context 'with the read-only token' do
    let(:token) { 'test-readonly-token' }
    let(:token_account) { create(:admin_user, community: community, superuser: true) }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(token_account.id.to_s)
    end

    it 'is refused and sends nothing' do
      expect { post "/residents/#{resident.id}/send_password_reset", params: { token: token } }
        .not_to(change { ActionMailer::Base.deliveries.count })

      expect(response).to have_http_status(:redirect)
      expect(resident.reload.reset_password_token).to be_nil
    end
  end
end
