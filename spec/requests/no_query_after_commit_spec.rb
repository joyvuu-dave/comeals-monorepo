# frozen_string_literal: true

require 'rails_helper'

# Every write action answers from what it read inside its own
# transaction, so nothing that runs after the commit can fail and answer
# "Nothing was saved. Try again." about a change that is in the database.
# At SERIALIZABLE any statement can be refused (ADR 0005), a read after
# the commit included, and the API's conflict rescue answers that 409
# with those words (ApiController#render_conflict).
#
# Before 2026-10-09 the settlement did not keep to this: after its commit
# it read the claimed meals again to clear their months from the cache,
# counted them for the answer, and queued the cook mail, and any of the
# three could fail and answer 409 for a settlement that was saved.
#
# Only steps that catch and report their own errors may run SQL after
# the commit (AfterCommitQueries::STEPS). Jobs go through Solid Queue, as
# in production: a job is then a row, so a job queued after the commit
# is a query this spec sees. The test adapter keeps jobs in memory and
# would hide it.
#
# Every route that writes needs an example here, the API's and admin's
# both; the last two examples check the lists against config/routes.rb.
# Admin answers a refused statement with the same words
# (config/initializers/active_admin_conflict_rescue.rb), and its writes
# run model callbacks that can do more than save one row: until
# 2026-10-10 a rotation delete renumbered and recolored the rotations
# after its commit, and an attendance removal read the resident's name
# for its notice after its commit.
RSpec.describe 'what a write runs after its commit' do
  include_context 'with no test transaction'
  include_context 'with Solid Queue as the job adapter'

  let(:password) { 'the-old-password' }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let!(:resident) { create(:resident, community: community, unit: unit, can_reconcile: true, password: password) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:token) { resident.keys.first.token }
  let(:meal) { create(:meal, community: community, date: community.today + 3) }
  let(:times) do
    { start_year: 2026, start_month: 4, start_day: 15, start_hours: 19, start_minutes: 0, end_hours: 21,
      end_minutes: 0 }
  end

  # One example for one write. The block sets up the rows and returns the
  # request as a lambda. The setup commits rows of its own (there is no
  # test transaction), so it runs before the recording starts. The route
  # goes into the example's metadata, for the last two examples.
  def self.write(route, admin: false, &setup)
    it "#{route} runs nothing after its commit", admin: admin, route: route do
      expect_nothing_after_the_commit(after_commit_queries(&instance_exec(&setup)), admin: admin)
    end
  end

  # The request saved, and ran nothing after its commit. An admin answers
  # a refused save with a redirect too, so for admin this also checks
  # that the page shows no alert.
  def expect_nothing_after_the_commit(result, admin:)
    expect(response).to have_http_status(:ok).or have_http_status(:created).or have_http_status(:found)
    expect(flash[:alert]).to be_nil if admin
    expect(result.committed).to be(true)
    expect(result.queries).to eq([]), "ran after the commit:\n#{result.queries.join("\n")}"
  end

  # The same for an admin route, signed in.
  # rubocop:disable-next Naming/BlockForwarding -- Ruby does not allow an anonymous block inside the `write` block
  def self.admin_write(route, &setup)
    write(route, admin: true) do
      sign_in_to_admin
      instance_exec(&setup)
    end
  end

  # Signs in as a superuser, who may make every admin write. Devise
  # writes the sign-in time on the first request after sign_in. That
  # write is the sign-in's, not the form's, so it happens here, before
  # the recording starts.
  def sign_in_to_admin(admin = create(:admin_user, community: community, superuser: true))
    host! 'admin.example.com'
    sign_in admin
    get '/'
  end

  # The route of each example in this file, nested groups included:
  # `[verb and path, admin?]`.
  def covered_routes
    self.class.parent_groups.last.descendants.flat_map(&:examples).filter_map do |example|
      [example.metadata[:route], example.metadata[:admin] == true] if example.metadata[:route]
    end
  end

  # Every route that writes: POST, PATCH and DELETE. Rails draws a PUT
  # next to the PATCH of each update action, and both run the same
  # action, so the PATCH example covers the PUT.
  def write_routes
    Rails.application.routes.routes.filter_map do |route|
      verb = route.verb == 'PUT' ? 'PATCH' : route.verb
      next unless %w[POST PATCH DELETE].include?(verb)

      yield("#{verb} #{route.path.spec.to_s.delete_suffix('(.:format)')}", route)
    end.uniq
  end

  # A meal from yesterday with a cook and someone who ate, so there is
  # something to settle.
  def settleable_meal
    settled = create(:meal, community: community, date: community.yesterday)
    create(:bill, meal: settled, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: settled, resident: resident, community: community)
  end

  write 'POST /api/v1/residents/password-reset' do
    -> { post '/api/v1/residents/password-reset', params: { email: resident.email } }
  end

  write 'POST /api/v1/residents/password-reset/:token' do
    resident.update!(reset_password_token: 'a-reset-token', reset_password_sent_at: Time.current)
    -> { post '/api/v1/residents/password-reset/a-reset-token', params: { password: 'a-new-password' } }
  end

  write 'DELETE /api/v1/sessions/current' do
    key = token
    -> { delete '/api/v1/sessions/current', params: { token: key } }
  end

  write 'POST /api/v1/meals/:meal_id/residents/:resident_id' do
    path = "/api/v1/meals/#{meal.id}/residents/#{resident.id}"
    -> { post path, params: { token: token, late: false, vegetarian: false } }
  end

  write 'PATCH /api/v1/meals/:meal_id/residents/:resident_id' do
    create(:meal_resident, meal: meal, resident: resident, community: community)
    path = "/api/v1/meals/#{meal.id}/residents/#{resident.id}"
    -> { patch path, params: { token: token, late: true } }
  end

  write 'DELETE /api/v1/meals/:meal_id/residents/:resident_id' do
    create(:meal_resident, meal: meal, resident: resident, community: community)
    path = "/api/v1/meals/#{meal.id}/residents/#{resident.id}"
    -> { delete path, params: { token: token } }
  end

  write 'POST /api/v1/meals/:meal_id/residents/:resident_id/guests' do
    path = "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests"
    -> { post path, params: { token: token, vegetarian: false }, headers: IdempotencyKey.header }
  end

  write 'DELETE /api/v1/meals/:meal_id/residents/:resident_id/guests/:guest_id' do
    guest = create(:guest, meal: meal, resident: resident)
    path = "/api/v1/meals/#{meal.id}/residents/#{resident.id}/guests/#{guest.id}"
    -> { delete path, params: { token: token } }
  end

  write 'PATCH /api/v1/meals/:meal_id/description' do
    path = "/api/v1/meals/#{meal.id}/description"
    -> { patch path, params: { token: token, description: 'Pasta' } }
  end

  write 'PATCH /api/v1/meals/:meal_id/max' do
    meal.update!(closed: true)
    path = "/api/v1/meals/#{meal.id}/max"
    -> { patch path, params: { token: token, max: 10 } }
  end

  write 'PATCH /api/v1/meals/:meal_id/bills' do
    path = "/api/v1/meals/#{meal.id}/bills"
    edits = [{ op: 'add', resident_id: cook.id, to: { amount: '12.00', no_cost: false } }]
    -> { patch path, params: { edits: edits, token: token }, headers: BillEdits.key_header, as: :json }
  end

  write 'PATCH /api/v1/meals/:meal_id/closed' do
    path = "/api/v1/meals/#{meal.id}/closed"
    -> { patch path, params: { token: token, closed: true } }
  end

  write 'POST /api/v1/reconciliations' do
    settleable_meal
    -> { post '/api/v1/reconciliations', params: { token: token, cutoff: community.yesterday.iso8601 } }
  end

  write 'POST /api/v1/events' do
    params = { title: 'Movie Night', description: '', all_day: false, **times }
    -> { post '/api/v1/events', params: { token: token, **params } }
  end

  write 'PATCH /api/v1/events/:id/update' do
    event = create(:event, community: community)
    -> { patch "/api/v1/events/#{event.id}/update", params: { token: token, title: 'After', **times } }
  end

  write 'DELETE /api/v1/events/:id/delete' do
    event = create(:event, community: community)
    -> { delete "/api/v1/events/#{event.id}/delete", params: { token: token } }
  end

  write 'POST /api/v1/guest-room-reservations' do
    params = { resident_id: resident.id, date: '2026-04-15' }
    -> { post '/api/v1/guest-room-reservations', params: { token: token, **params } }
  end

  write 'PATCH /api/v1/guest-room-reservations/:id/update' do
    reservation = create(:guest_room_reservation, community: community, resident: resident)
    path = "/api/v1/guest-room-reservations/#{reservation.id}/update"
    -> { patch path, params: { token: token, resident_id: resident.id, date: '2026-04-16' } }
  end

  write 'DELETE /api/v1/guest-room-reservations/:id/delete' do
    reservation = create(:guest_room_reservation, community: community, resident: resident)
    -> { delete "/api/v1/guest-room-reservations/#{reservation.id}/delete", params: { token: token } }
  end

  write 'POST /api/v1/common-house-reservations' do
    params = { resident_id: resident.id, title: 'Party', **times }
    -> { post '/api/v1/common-house-reservations', params: { token: token, **params } }
  end

  write 'PATCH /api/v1/common-house-reservations/:id/update' do
    reservation = create(:common_house_reservation, community: community, resident: resident)
    path = "/api/v1/common-house-reservations/#{reservation.id}/update"
    -> { patch path, params: { token: token, resident_id: resident.id, title: 'Party', **times } }
  end

  write 'DELETE /api/v1/common-house-reservations/:id/delete' do
    reservation = create(:common_house_reservation, community: community, resident: resident)
    -> { delete "/api/v1/common-house-reservations/#{reservation.id}/delete", params: { token: token } }
  end

  # Log in writes nothing: the token is a JWT, signed and not stored.
  it 'POST /api/v1/residents/token commits nothing', route: 'POST /api/v1/residents/token' do
    params = { email: resident.email, password: password }
    result = after_commit_queries { post '/api/v1/residents/token', params: params }

    expect(response).to have_http_status(:ok)
    expect(result.committed).to be(false)
  end

  # --- admin ---------------------------------------------------------------

  # Devise's own routes: signing in, and the forgotten-password pair.
  # Each starts signed out.
  write 'POST /login', admin: true do
    admin = create(:admin_user, community: community, password: 'a-password', password_confirmation: 'a-password')
    host! 'admin.example.com'
    -> { post '/login', params: { admin_user: { email: admin.email, password: 'a-password' } } }
  end

  context 'with the mail host production sets' do
    # Devise's reset mail links to the admin host. Production names it
    # (config/environments/production.rb); the test environment does not.
    around do |example|
      default_url_options = ActionMailer::Base.default_url_options
      ActionMailer::Base.default_url_options = { host: 'admin.example.com' }
      example.run
    ensure
      ActionMailer::Base.default_url_options = default_url_options
    end

    write 'POST /password', admin: true do
      admin = create(:admin_user, community: community)
      host! 'admin.example.com'
      -> { post '/password', params: { admin_user: { email: admin.email } } }
    end

    # Devise saves the new password and then signs the admin in, and the
    # sign-in time is a second transaction, Devise's own. Devise's
    # controllers have no conflict rescue (only ActiveAdmin's do), so a
    # refusal of that second write is an error page, not a false
    # "Nothing was saved", and the new password works at the next
    # sign-in. Nothing else may run after the first commit.
    it 'PATCH /password runs only the sign-in write after its commit', :admin, route: 'PATCH /password' do
      admin = create(:admin_user, community: community)
      token = admin.send_reset_password_instructions
      host! 'admin.example.com'
      params = { reset_password_token: token, password: 'a-new-password', password_confirmation: 'a-new-password' }

      result = after_commit_queries { patch '/password', params: { admin_user: params } }

      expect(response).to have_http_status(:found)
      expect(result.committed).to be(true)
      expect(result.queries).to match(
        [eq('BEGIN'), start_with('UPDATE "admin_users" SET "current_sign_in_at"'), eq('COMMIT')]
      )
    end
  end

  admin_write 'POST /admin_users' do
    params = { email: 'new-admin@example.com', password: 'a-password', password_confirmation: 'a-password' }
    -> { post '/admin_users', params: { admin_user: params } }
  end

  admin_write 'PATCH /admin_users/:id' do
    other = create(:admin_user, community: community)
    -> { patch "/admin_users/#{other.id}", params: { admin_user: { email: 'renamed@example.com', password: '' } } }
  end

  admin_write 'DELETE /admin_users/:id' do
    other = create(:admin_user, community: community)
    -> { delete "/admin_users/#{other.id}" }
  end

  admin_write 'POST /bills' do
    params = { meal_id: meal.id, resident_id: cook.id, amount: '12.00' }
    -> { post '/bills', params: { bill: params } }
  end

  admin_write 'PATCH /bills/:id' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    -> { patch "/bills/#{bill.id}", params: { bill: { amount: '15.00' } } }
  end

  admin_write 'DELETE /bills/:id' do
    bill = create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    -> { delete "/bills/#{bill.id}" }
  end

  admin_write 'POST /common_house_reservations' do
    params = { resident_id: resident.id, title: 'Party', start_date: '2026-05-20 14:00:00',
               end_date: '2026-05-20 16:00:00' }
    -> { post '/common_house_reservations', params: { common_house_reservation: params } }
  end

  admin_write 'PATCH /common_house_reservations/:id' do
    reservation = create(:common_house_reservation, community: community, resident: resident)
    path = "/common_house_reservations/#{reservation.id}"
    -> { patch path, params: { common_house_reservation: { title: 'After' } } }
  end

  admin_write 'DELETE /common_house_reservations/:id' do
    reservation = create(:common_house_reservation, community: community, resident: resident)
    -> { delete "/common_house_reservations/#{reservation.id}" }
  end

  # The one community is made once, on an empty database, by the first
  # admin (spec/requests/admin/bootstrap_guard_spec.rb).
  context 'with no community yet' do
    let!(:resident) { nil }

    it 'POST /communities runs nothing after its commit', :admin, route: 'POST /communities' do
      sign_in_to_admin(create(:admin_user, community: nil, superuser: true))
      params = { name: 'Patches Way', cap: '2.50', timezone: 'America/Los_Angeles' }

      result = after_commit_queries { post '/communities', params: { community: params } }

      expect_nothing_after_the_commit(result, admin: true)
    end
  end

  admin_write 'PATCH /communities/:id' do
    -> { patch "/communities/#{community.id}", params: { community: { name: 'Renamed' } } }
  end

  # The live preview under the schedule grid reads and writes nothing.
  it 'POST /communities/schedule_preview commits nothing', :admin, route: 'POST /communities/schedule_preview' do
    sign_in_to_admin
    params = { schedule: { '0' => ['', '0', '2', '4'] }, meals_per_rotation: 12 }
    result = after_commit_queries { post '/communities/schedule_preview', params: { community: params } }

    expect(response).to have_http_status(:ok)
    expect(result.committed).to be(false)
  end

  admin_write 'POST /events' do
    params = { title: 'Movie Night', start_date: '2026-05-01 18:00:00', end_date: '2026-05-01 20:00:00' }
    -> { post '/events', params: { event: params } }
  end

  admin_write 'PATCH /events/:id' do
    event = create(:event, community: community)
    -> { patch "/events/#{event.id}", params: { event: { title: 'After' } } }
  end

  admin_write 'DELETE /events/:id' do
    event = create(:event, community: community)
    -> { delete "/events/#{event.id}" }
  end

  admin_write 'POST /guest_room_reservations' do
    params = { resident_id: resident.id, date: '2026-05-15' }
    -> { post '/guest_room_reservations', params: { guest_room_reservation: params } }
  end

  admin_write 'PATCH /guest_room_reservations/:id' do
    reservation = create(:guest_room_reservation, community: community, resident: resident)
    path = "/guest_room_reservations/#{reservation.id}"
    -> { patch path, params: { guest_room_reservation: { date: '2026-05-16' } } }
  end

  admin_write 'DELETE /guest_room_reservations/:id' do
    reservation = create(:guest_room_reservation, community: community, resident: resident)
    -> { delete "/guest_room_reservations/#{reservation.id}" }
  end

  # Before the last meal of the calendar: the form refuses a date after
  # it (#143).
  admin_write 'POST /meals' do
    rotation = meal.rotation
    date = (meal.date - 1).iso8601
    -> { post '/meals', params: { meal: { date: date, closed: '0', rotation_id: rotation.id } } }
  end

  admin_write 'PATCH /meals/:id' do
    path = "/meals/#{meal.id}"
    -> { patch path, params: { meal: { closed: '1', max: '5' } } }
  end

  admin_write 'DELETE /meals/:id' do
    path = "/meals/#{meal.id}"
    -> { delete path }
  end

  admin_write 'POST /meals/:meal_id/meal_residents' do
    path = "/meals/#{meal.id}/meal_residents"
    -> { post path, params: { meal_resident: { resident_id: resident.id } } }
  end

  admin_write 'DELETE /meals/:meal_id/meal_residents/:id' do
    row = create(:meal_resident, meal: meal, resident: resident, community: community)
    -> { delete "/meals/#{meal.id}/meal_residents/#{row.id}" }
  end

  admin_write 'POST /reconciliations' do
    settleable_meal
    -> { post '/reconciliations', params: { reconciliation: { end_date: community.yesterday } } }
  end

  admin_write 'PATCH /residents/:id/remove_birthday' do
    resident.update!(birthday: Date.new(1980, 4, 15))
    -> { patch "/residents/#{resident.id}/remove_birthday" }
  end

  admin_write 'POST /residents/:id/send_password_reset' do
    -> { post "/residents/#{resident.id}/send_password_reset" }
  end

  admin_write 'POST /residents' do
    params = { name: 'New Resident', email: 'new-resident@example.com', password: 'a-password', kind: 'adult',
               unit_id: unit.id }
    -> { post '/residents', params: { resident: params } }
  end

  admin_write 'PATCH /residents/:id' do
    -> { patch "/residents/#{resident.id}", params: { resident: { name: 'Renamed' } } }
  end

  admin_write 'DELETE /residents/:id' do
    leaving = create(:resident, community: community, unit: unit)
    -> { delete "/residents/#{leaving.id}" }
  end

  # Two upcoming rotations, because only the last may be deleted, and
  # deleting it renumbers and recolors the other.
  admin_write 'DELETE /rotations/:id' do
    first = create(:rotation, community: community)
    create(:meal, community: community, rotation: first, date: community.today + 30)
    last = create(:rotation, community: community)
    create(:meal, community: community, rotation: last, date: community.today + 40)
    -> { delete "/rotations/#{last.id}" }
  end

  admin_write 'POST /units' do
    -> { post '/units', params: { unit: { name: 'B-2' } } }
  end

  admin_write 'PATCH /units/:id' do
    -> { patch "/units/#{unit.id}", params: { unit: { name: 'B-3' } } }
  end

  admin_write 'DELETE /units/:id' do
    empty = create(:unit, community: community)
    -> { delete "/units/#{empty.id}" }
  end

  it 'has an example for every API route that writes' do
    routes = write_routes { |route, _| route if route.include?(' /api/') }
    covered = covered_routes.reject { |_, admin| admin }.map(&:first)

    expect(covered).to match_array(routes)
  end

  # The admin routes with no example, and why.
  def admin_routes_not_run
    {
      # config/routes.rb answers these with a 404 before ActiveAdmin's
      # comments controller (comments are off, #82), so they write nothing
      # (spec/requests/admin/comments_routes_spec.rb).
      'POST /comments' => :answered_with_a_not_found,
      'DELETE /comments/:id' => :answered_with_a_not_found
    }
  end

  it 'has an example for every admin route that writes, or says why not' do
    routes = write_routes { |route, rails_route| route if rails_route.constraints[:subdomain] == 'admin' }
    covered = covered_routes.select { |_, admin| admin }.map(&:first)

    expect(covered + admin_routes_not_run.keys).to match_array(routes)
  end
end
