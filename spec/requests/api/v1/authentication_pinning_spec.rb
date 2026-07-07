# frozen_string_literal: true

require 'rails_helper'

# ADR 0002: authentication is the one boundary the API actually keeps. Every
# write must require a signed-in resident, and so must the two authenticated
# read endpoints the audit flagged (birthdays, calendar). These are pinned in
# one place so a stray `only:`/`except:` on a controller's `before_action
# :authenticate` — which would silently open a write — fails a test.
#
# Auth runs before any record lookup, so a nonexistent id still yields 401,
# never 404. The routes are listed with placeholder ids for that reason.
RSpec.describe 'API authentication boundary' do
  # method, path — every state-changing route plus the flagged authenticated GETs
  endpoints = [
    # Meals: attendance, guests, and the shared meal controls
    [:post,   '/api/v1/meals/1/residents/1'],
    [:delete, '/api/v1/meals/1/residents/1'],
    [:patch,  '/api/v1/meals/1/residents/1'],
    [:post,   '/api/v1/meals/1/residents/1/guests'],
    [:delete, '/api/v1/meals/1/residents/1/guests/1'],
    [:patch,  '/api/v1/meals/1/description'],
    [:patch,  '/api/v1/meals/1/max'],
    [:patch,  '/api/v1/meals/1/bills'],
    [:patch,  '/api/v1/meals/1/closed'],
    # Events
    [:post,   '/api/v1/events'],
    [:patch,  '/api/v1/events/1/update'],
    [:delete, '/api/v1/events/1/delete'],
    # Guest room reservations
    [:post,   '/api/v1/guest-room-reservations'],
    [:patch,  '/api/v1/guest-room-reservations/1/update'],
    [:delete, '/api/v1/guest-room-reservations/1/delete'],
    # Common house reservations
    [:post,   '/api/v1/common-house-reservations'],
    [:patch,  '/api/v1/common-house-reservations/1/update'],
    [:delete, '/api/v1/common-house-reservations/1/delete'],
    # Session teardown
    [:delete, '/api/v1/sessions/current'],
    # Authenticated reads the audit flagged as unpinned
    [:get,    '/api/v1/communities/1/birthdays'],
    [:get,    '/api/v1/communities/1/hosts'],
    [:get,    '/api/v1/communities/1/calendar/2026-01-01'],
    [:get,    '/api/v1/residents/id']
  ]

  endpoints.each do |method, path|
    describe "#{method.to_s.upcase} #{path}" do
      it 'returns 401 with no token' do
        public_send(method, path)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 with a garbage token' do
        public_send(method, path, params: { token: 'not-a-real-token' })
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
