# frozen_string_literal: true

require 'rails_helper'

# A request from the meal page's sign-up list can reach the server after
# the page stopped waiting for it (35 s) and loaded the meal again. When
# it is still written, the page that sent it must be told, or its screen
# shows the meal without the change until the next load (#237).
#
# So a request that carries a push_token is not left out of the meal
# page's push by its socket id. The push goes to every screen, the
# sender's too, and carries the request's token. A page skips a push only
# when every token in it is one of its own requests that it has not given
# up on (data_store_signup_requests.ts).
#
# A request with no push_token (a page loaded before this change, or a
# write that does not send one) is left out by its socket id, as before.
RSpec.describe 'The meal page push for a request that carries a push_token' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:alice) { create(:resident, community: community, unit: unit) }
  let(:token) { alice.keys.first.token }
  let(:meal) { create(:meal, community: community, date: community.today + 3) }
  let(:path) { "/api/v1/meals/#{meal.id}/residents/#{alice.id}" }
  let(:sent) { { token: token, socket_id: 'sender-socket', push_token: 'tap-1' } }

  def meal_pushes
    pushes = []
    allow(Pusher).to receive(:trigger) { |*args| pushes << args if args.first == "meal-#{meal.id}" }
    yield
    pushes
  end

  def sign_up_alice
    create(:meal_resident, meal: meal, resident: alice, community: community)
  end

  def add_guest(params)
    post "#{path}/guests", params: params.merge(vegetarian: false), headers: BillEdits.key_header, as: :json
  end

  def guest_path
    "#{path}/guests/#{create(:guest, meal: meal, resident: alice).id}"
  end

  # What each request needs before it is sent, and the request. The setup
  # runs before the pushes are recorded.
  {
    'a sign-up' => [nil, ->(at, sent) { post at, params: sent.merge(late: false, vegetarian: false), as: :json }],
    'a take-off' => [:sign_up_alice, ->(at, sent) { delete at, params: sent, as: :json }],
    'a Late change' => [:sign_up_alice, ->(at, sent) { patch at, params: sent.merge(late: true), as: :json }],
    'a Veg change' => [:sign_up_alice, ->(at, sent) { patch at, params: sent.merge(vegetarian: true), as: :json }],
    'a guest add' => [nil, ->(_at, sent) { add_guest(sent) }],
    'a guest removal' => [:guest_path, ->(at, sent) { delete at, params: sent, as: :json }]
  }.each do |what, (setup, send_request)|
    it "pushes #{what} to the sender too, with the request's token" do
      at = setup == :guest_path ? guest_path : path
      send(setup) if setup == :sign_up_alice
      pushes = meal_pushes { instance_exec(at, sent, &send_request) }

      expect(response).to have_http_status(:ok)
      expect(pushes).to eq([["meal-#{meal.id}", 'update', { message: 'meal updated', push_tokens: ['tap-1'] }]])
    end
  end
end
