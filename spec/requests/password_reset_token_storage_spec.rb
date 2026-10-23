# frozen_string_literal: true

require 'rails_helper'

# A reset token that is still live is as good as the password: whoever has
# it can set this person's password. So the database keeps only a SHA-256
# digest of it, and the token itself exists only in the email. Someone who
# reads the residents table (a backup, a copy of production, a log of a
# query) learns nothing they can use.
RSpec.describe 'Where a password reset token is kept' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit, email: 'sarah@example.com') }

  # The token in the link of the last email sent.
  def mailed_token
    link = ActionMailer::Base.deliveries.last.text_part.body.decoded[%r{https?://\S+/reset-password\S*}]
    link.delete_suffix('.')[%r{reset-password(?:/|#token=)([\w-]+)}, 1]
  end

  # Every value in the resident's row, read with SQL, so no model code
  # can leave a column out.
  def stored_values
    ActiveRecord::Base.connection.select_one("SELECT * FROM residents WHERE id = #{Integer(resident.id)}")
                      .values.compact.map(&:to_s)
  end

  def expect_only_a_digest_stored(token)
    expect(token).to be_present
    expect(stored_values.select { |value| value.include?(token) }).to eq([])
    expect(stored_values).to include(Digest::SHA256.hexdigest(token))
  end

  it 'keeps only a digest of the token a resident asked for' do
    post '/api/v1/residents/password-reset', params: { email: 'sarah@example.com' }
    expect(response).to have_http_status(:ok)

    expect_only_a_digest_stored(mailed_token)
  end

  it 'keeps only a digest of the token an admin had sent' do
    host! 'admin.example.com'
    sign_in create(:admin_user, community: community, superuser: false)

    post "/residents/#{resident.id}/send_password_reset"
    expect(response).to redirect_to("/residents/#{resident.id}")

    expect_only_a_digest_stored(mailed_token)
  end
end
