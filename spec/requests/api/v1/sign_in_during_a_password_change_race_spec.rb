# frozen_string_literal: true

require 'rails_helper'

# A password change signs out every session: it sets keys_valid_since to
# the time of the change, and JwtAuth refuses a token made before it.
#
# Here a sign-in with the old password runs while the change is saved but
# not yet committed. The sign-in reads the old digest, because the change
# is not committed, so the old password still works. It makes its token
# after the change set keys_valid_since, so the token's time is later and
# the token is not refused. After the commit, the old password made a
# token that the password change did not sign out.
RSpec.describe 'signing in with the old password while the password is being changed' do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) do
    create(:resident, community: community, unit: unit, email: 'cook@example.com', password: 'old password')
  end

  it 'does not give out a token that outlives the change' do
    resident
    changed = Queue.new
    commit = Queue.new

    change = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        Resident.transaction do
          Resident.find(resident.id).update!(password: 'new password')
          changed << true
          commit.pop
        end
      end
    end

    changed.pop
    post '/api/v1/residents/token', params: { email: 'cook@example.com', password: 'old password' }
    commit << true
    change.join

    token = response.parsed_body['token']
    expect(JwtAuth.authenticate(token)).to be_nil
  end
end
