# frozen_string_literal: true

require 'rails_helper'

# ADR 0002: admin writes are the one authorization boundary the system keeps.
# SuperuserAdapter allows every admin to read but restricts create/update/destroy
# to superusers. spec/models/superuser_adapter_spec.rb proves the adapter logic in
# isolation; this proves ActiveAdmin actually invokes it end-to-end through routing,
# so removing the adapter wiring or a resource opting out would fail a test.
#
# The Event resource is used because it has full CRUD and no financial dependents.
RSpec.describe 'Admin superuser write authorization' do
  let(:community) { create(:community) }
  let!(:event) { create(:event, community: community) }

  before { host! 'admin.example.com' }

  context 'when signed in as a non-superuser admin' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it 'may read the index' do
      get '/events'
      expect(response).to have_http_status(:ok)
    end

    # ActiveAdmin denies via a redirect to the admin root with a flash error,
    # not a 403 (on_unauthorized_access is unset, so the default handler runs).
    def expect_denied
      expect(response).to redirect_to('http://admin.example.com/')
      expect(flash[:error]).to eq('You are not authorized to perform this action.')
    end

    it 'is denied destroy and the record survives' do
      expect do
        delete "/events/#{event.id}"
      end.not_to change(Event, :count)

      expect_denied
      expect(Event.exists?(event.id)).to be true
    end

    it 'is denied update and the record is unchanged' do
      patch "/events/#{event.id}", params: { event: { title: 'Hijacked' } }

      expect_denied
      expect(event.reload.title).not_to eq('Hijacked')
    end

    it 'is denied create' do
      expect do
        post '/events', params: {
          event: { title: 'Sneaky', start_date: 1.day.from_now, community_id: community.id }
        }
      end.not_to change(Event, :count)

      expect_denied
    end
  end

  context 'when signed in as a superuser admin' do
    before { sign_in create(:admin_user, community: community, superuser: true) }

    it 'may destroy' do
      expect do
        delete "/events/#{event.id}"
      end.to change(Event, :count).by(-1)

      expect(response).to redirect_to('/events')
    end

    it 'may update' do
      patch "/events/#{event.id}", params: { event: { title: 'Legit change' } }

      expect(event.reload.title).to eq('Legit change')
    end
  end
end
