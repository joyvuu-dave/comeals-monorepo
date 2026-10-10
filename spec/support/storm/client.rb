# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require_relative '../bill_edits'

module Storm
  # One phone at dinner time: a resident sending requests as fast as the
  # server answers them, until the deadline. Each request is picked at
  # random from the whole API: meal writes, calendar writes, reads,
  # logins, and for a reconciler, previews and settlements.
  #
  # The client speaks only HTTP. It knows nothing about the database, so
  # the same client runs in-process against the Rack app (the RSpec
  # storm) and over TCP against a real Puma (rake test:storm). The
  # transport is a callable:
  #
  #   transport.call(method, path, headers, body, ip) -> [status, body]
  #
  # What it records, one Entry per request: the action, the meal, the
  # status, and what was wrong with the answer, if anything. Wrong means:
  #   - a status the API does not answer for that action (a 500 above all);
  #   - an exception out of the transport (in-process, an unrescued error
  #     is what a 500 would be);
  #   - an answer that belongs to someone else: /residents/id must answer
  #     this client's id, and a login must answer this client's resident;
  #   - a 429 the throttle had no grounds for. The client counts its own
  #     requests per throttle window (every client has its own IP), so a
  #     429 under the limit means the counter held someone else's requests.
  class Client
    # ms is the round trip as the client saw it, from sending the request
    # to reading the whole answer, in milliseconds.
    Entry = Struct.new(:client, :n, :action, :meal_id, :status, :problem, :ms, keyword_init: true)

    # config/initializers/rack_attack.rb
    API_LIMIT = 600
    API_PERIOD = 60
    LOGIN_LIMIT = 20
    LOGIN_PERIOD = 300

    # How often each action is picked. Writes to meals dominate, the way
    # they do at dinner time.
    WEIGHTS = {
      signup: 14, leave: 8, toggle: 5, add_guest: 6, remove_guest: 4, bills: 6,
      close: 3, reopen: 3, max: 3, description: 3,
      cooks: 8, history: 3, calendar: 8, next_meal: 2, whoami: 6, ical: 2, hosts: 2, birthdays: 2,
      rotation: 2, login: 1,
      event_create: 3, event_delete: 2, guest_room_create: 2, guest_room_delete: 1,
      common_house_create: 2, common_house_delete: 1,
      preview: 2, settle: 2
    }.freeze

    MEAL_WRITE = [200, 400, 409].freeze # written, refused by a rule, or a conflict
    # A row that is already gone (this client left, or the admin removed it).
    ROW_WRITE = (MEAL_WRITE + [404]).freeze
    READ = [200].freeze

    # PostgreSQL can refuse any transaction at SERIALIZABLE, and every
    # request the app answers runs at least one. So 409 is a valid answer
    # to anything — the app's own words for it are "nothing was saved, try
    # again" (ApiController#render_conflict, ADR 0005). What is never
    # valid is a 500, and the counts below still hold: a run where
    # everything answered 409 would write nothing and settle nothing.
    CONFLICT = 409
    EXPECTED = {
      signup: MEAL_WRITE, leave: ROW_WRITE, toggle: ROW_WRITE, add_guest: MEAL_WRITE,
      remove_guest: MEAL_WRITE, bills: MEAL_WRITE, close: MEAL_WRITE, reopen: MEAL_WRITE,
      max: MEAL_WRITE, description: MEAL_WRITE,
      cooks: READ, history: READ, calendar: READ, next_meal: READ, whoami: READ, ical: READ,
      hosts: READ, birthdays: READ, rotation: READ, login: READ,
      # This client's own events and previews can never be refused: an
      # event always has a title and ends an hour after it starts, and the
      # preview asks for yesterday. So a 400 for either is a problem. A
      # guest room or a common house booking can be taken already.
      event_create: READ, event_delete: READ,
      guest_room_create: [200, 400], guest_room_delete: READ,
      common_house_create: [200, 400], common_house_delete: READ,
      preview: READ, settle: [201, 400, 409]
    }.freeze

    MEAL_WRITES = %i[signup leave toggle add_guest remove_guest bills close reopen max description].freeze
    ROW_WRITES = %i[signup leave toggle add_guest remove_guest bills].freeze
    # The writes that need an Idempotency-Key header.
    KEYED = %i[bills add_guest].freeze
    RECONCILER_ONLY = %i[preview settle].freeze

    attr_reader :log, :meal_sockets

    def initialize(index:, plan:, transport:, rng:, deadline:)
      @index = index
      @plan = plan
      @transport = transport
      @rng = rng
      @deadline = deadline
      @resident = plan.residents.fetch(index)
      @token = plan.tokens.fetch(@resident.id)
      @home = plan.meals.fetch(index % plan.meals.size)
      @ip = "10.9.#{index / 250}.#{(index % 250) + 1}"
      @n = 0
      @log = []
      # Every (meal id, socket id) pair this client sent with a meal write.
      # A meal push must carry one of these for its meal (LiveUpdate).
      @meal_sockets = Set.new
      @guests = Hash.new { |h, k| h[k] = [] }
      # The bills this client last saw for each meal, by cook: what a bills
      # save names as `from` (#135).
      @bills_seen = {}
      @events = []
      @guest_rooms = []
      @common_houses = []
      @sent = Hash.new(0)
      @weights = WEIGHTS.reject { |action, _| RECONCILER_ONLY.include?(action) && !@resident.can_reconcile? }
    end

    def run
      step while Process.clock_gettime(Process::CLOCK_MONOTONIC) < @deadline
      self
    end

    # One request. Public so a spec can drive a client by hand.
    def step(action = pick_action)
      @n += 1
      meal = pick_meal
      method, path, body, check, done = send(:"request_#{action}", meal)
      # A delete with nothing to delete creates instead; judge what was sent.
      action = done if done
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, response = call(method, path, body, action)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      problem = judge(action, status, response, check)
      @log << Entry.new(client: @index, n: @n, action: action, meal_id: meal.id, status: status, problem: problem,
                        ms: ms)
    rescue StandardError => e
      @log << Entry.new(client: @index, n: @n, action: action, meal_id: meal&.id, status: :exception,
                        problem: "#{e.class}: #{e.message}\n  #{e.backtrace.first(12).join("\n  ")}")
    end

    private

    def pick_action
      total = @weights.values.sum
      roll = @rng.rand(total)
      @weights.each do |action, weight|
        return action if roll < weight

        roll -= weight
      end
      @weights.keys.last
    end

    # Half the time the client's own meal, so every meal has a few clients
    # who keep coming back to it; otherwise any meal.
    def pick_meal
      @rng.rand < 0.5 ? @home : @plan.meals.sample(random: @rng)
    end

    # A bills save and a guest add carry a new Idempotency-Key, as the
    # page sends one (decision 6 of #135, S2): this client and request
    # number, which no other request has.
    def call(method, path, body, action)
      headers = { 'Authorization' => "Bearer #{@token}" }
      headers['Idempotency-Key'] = %("storm-#{@index}-#{@n}") if KEYED.include?(action)
      login = action == :login
      note_sent(login)
      status, response = @transport.call(method, path, headers, body && JSON.generate(body), @ip)
      [status, response]
    end

    # --- what the API promises, per action ---------------------------------

    def judge(action, status, response, check)
      return nil if status == CONFLICT
      return nil if EXPECTED.fetch(action).include?(status) && (check.nil? || check.call(response))
      return nil if status == 429 && throttled_with_reason?(action == :login)
      return "false 429: #{@sent.inspect}" if status == 429
      return "answered someone else: #{response[0, 200]}" if EXPECTED.fetch(action).include?(status)

      "unexpected #{status}: #{response.to_s[0, 400]}"
    end

    def note_sent(login)
      now = Time.now.to_i
      @sent[[API_PERIOD, now / API_PERIOD]] += 1
      @sent[[LOGIN_PERIOD, now / LOGIN_PERIOD]] += 1 if login
    end

    # Rack::Attack counts in fixed windows aligned to the epoch. A request
    # sent at the edge of a window may be counted by the server in the
    # next one, so the window before counts too.
    def throttled_with_reason?(login)
      now = Time.now.to_i
      over?(API_PERIOD, API_LIMIT, now) || (login && over?(LOGIN_PERIOD, LOGIN_LIMIT, now))
    end

    def over?(period, limit, now)
      window = now / period
      @sent[[period, window]] > limit || @sent[[period, window - 1]] > limit
    end

    # --- the requests -------------------------------------------------------
    # Each returns [method, path, body, check]; check reads the response.

    def socket
      "sock-#{@index}-#{@n}"
    end

    def meal_write(meal, method, path, body)
      @meal_sockets << [meal.id, socket]
      [method, "/api/v1/meals/#{meal.id}#{path}", body.merge(socket_id: socket), nil]
    end

    def request_signup(meal)
      meal_write(meal, :post, "/residents/#{@resident.id}", { late: @rng.rand < 0.3, vegetarian: @rng.rand < 0.2 })
    end

    def request_leave(meal)
      meal_write(meal, :delete, "/residents/#{@resident.id}", {})
    end

    def request_toggle(meal)
      meal_write(meal, :patch, "/residents/#{@resident.id}", { late: @rng.rand < 0.5 })
    end

    def request_add_guest(meal)
      method, path, body = meal_write(meal, :post, "/residents/#{@resident.id}/guests", { vegetarian: @rng.rand < 0.2 })
      [method, path, body, ->(response) { remember_guest(meal, response) }]
    end

    def remember_guest(meal, response)
      id = JSON.parse(response)['id']
      @guests[meal.id] << id if id
      true
    end

    def request_remove_guest(meal)
      id = @guests[meal.id].shift
      return request_add_guest(meal) + [:add_guest] if id.nil?

      meal_write(meal, :delete, "/residents/#{@resident.id}/guests/#{id}", {})
    end

    # A bills save the way the page sends it (#135): the cooks picked here
    # become the meal's cooks, as edits from the bills this client last
    # saw. Without a copy it reads the meal form instead, the way a page
    # loads a meal before it can save one. A copy is used once: a save
    # that is refused (a stale 409, when another client saved first) gives
    # no new copy, so the next bills request reads the form again.
    def request_bills(meal)
      seen = @bills_seen.delete(meal.id)
      return request_cooks(meal) + [:cooks] if seen.nil?

      cooks = @plan.residents.sample(@rng.rand(1..3), random: @rng)
      wanted = cooks.to_h do |cook|
        no_cost = @rng.rand < 0.15
        [cook.id, { amount: no_cost ? BigDecimal('0') : BigDecimal(@rng.rand(0..999_999)) / 100, no_cost: no_cost }]
      end
      method, path, body = meal_write(meal, :patch, '/bills', { edits: BillEdits.between(seen, wanted) })
      [method, path, body, ->(response) { remember_bills(meal, response) }]
    end

    # The bills in a meal form, or in a bills answer that has them: a save
    # and a warning do, a refusal does not. judge never calls a check on a
    # 409, so after one the client has no copy and reads the form again.
    def remember_bills(meal, response)
      bills = JSON.parse(response)['bills']
      if bills
        @bills_seen[meal.id] = bills.to_h do |bill|
          [bill['resident_id'], { amount: BigDecimal(bill['amount']), no_cost: bill['no_cost'] }]
        end
      end
      true
    end

    def request_close(meal)
      meal_write(meal, :patch, '/closed', { closed: true })
    end

    def request_reopen(meal)
      meal_write(meal, :patch, '/closed', { closed: false })
    end

    def request_max(meal)
      meal_write(meal, :patch, '/max', { max: @rng.rand(0..8) })
    end

    def request_description(meal)
      meal_write(meal, :patch, '/description', { description: "storm #{@index} #{@n}" })
    end

    def request_cooks(meal)
      [:get, "/api/v1/meals/#{meal.id}/cooks", nil, ->(response) { remember_bills(meal, response) }]
    end

    def request_history(meal)
      [:get, "/api/v1/meals/#{meal.id}/history", nil, nil]
    end

    def request_calendar(meal)
      [:get, "/api/v1/communities/#{@plan.community.id}/calendar/#{meal.date.iso8601}", nil,
       ->(response) { remember_calendar(response) }]
    end

    # The ids of this client's own calendar rows, from the month it just
    # read, so it can delete them later. Only its own: another client's
    # rows are theirs to delete. Events and common house bookings carry
    # the title this client gave them. A guest room carries only the
    # resident's name as the calendar shows it (own_name_line).
    def remember_calendar(response)
      month = JSON.parse(response)
      @events = row_ids(month.fetch('events')) { |e| e['title'].include?("storm-event-#{@index}-") }
      @guest_rooms = row_ids(month.fetch('guest_room_reservations')) { |r| r['title'].include?(own_name_line) }
      @common_houses = row_ids(month.fetch('common_house_reservations')) do |r|
        r['title'].include?("storm-chr-#{@index}-")
      end
      true
    end

    # The calendar shows a resident by the short name, on a line of its
    # own before the unit. It is not the full name: "Storm Client 0" is
    # "Storm 0" there, because no one else's name ends in 0, and a client
    # that looked for its full name never found its rows and never sent a
    # delete. Every resident in the storm is a client, so the plan has
    # every name the app shortens against.
    def own_name_line
      @own_name_line ||= "\n#{ResidentNameShortener.new(@plan.residents.map(&:name)).short(@resident.name)} - Unit "
    end

    # A calendar row's id is "events/80-20260911150149946146" (the SPA's
    # key); the record id is the number after the slash.
    def row_ids(rows, &)
      rows.select(&).map { |row| Integer(row.fetch('id')[%r{/(\d+)-}, 1]) }
    end

    def request_next_meal(_meal)
      [:get, '/api/v1/meals/next', nil, nil]
    end

    def request_whoami(_meal)
      [:get, '/api/v1/residents/id', nil, ->(response) { response.strip == @resident.id.to_s }]
    end

    def request_ical(_meal)
      [:get, "/api/v1/residents/#{@resident.id}/ical", nil, nil]
    end

    def request_hosts(_meal)
      [:get, "/api/v1/communities/#{@plan.community.id}/hosts", nil, nil]
    end

    def request_birthdays(_meal)
      [:get, "/api/v1/communities/#{@plan.community.id}/birthdays", nil, nil]
    end

    def request_rotation(meal)
      [:get, "/api/v1/rotations/#{meal.rotation_id}", nil, nil]
    end

    def request_login(_meal)
      [:post, '/api/v1/residents/token', { email: @resident.email, password: 'storm' },
       ->(response) { JSON.parse(response)['resident_id'] == @resident.id }]
    end

    def request_event_create(meal)
      day = meal.date
      start_hour = @rng.rand(6..20)
      [:post, '/api/v1/events',
       { title: "storm-event-#{@index}-#{@n}", description: '', all_day: false,
         start_year: day.year, start_month: day.month, start_day: day.day,
         start_hours: start_hour, start_minutes: 0, end_hours: start_hour + 1, end_minutes: 0 }, nil]
    end

    def request_event_delete(meal)
      id = @events.shift
      return request_event_create(meal) + [:event_create] if id.nil?

      [:delete, "/api/v1/events/#{id}/delete", nil, nil]
    end

    def request_guest_room_create(meal)
      [:post, '/api/v1/guest-room-reservations',
       { resident_id: @resident.id, date: (meal.date + @rng.rand(0..6)).iso8601 }, nil]
    end

    def request_guest_room_delete(meal)
      id = @guest_rooms.shift
      return request_guest_room_create(meal) + [:guest_room_create] if id.nil?

      [:delete, "/api/v1/guest-room-reservations/#{id}/delete", nil, nil]
    end

    def request_common_house_create(meal)
      day = meal.date
      start_hour = @rng.rand(6..20)
      [:post, '/api/v1/common-house-reservations',
       { resident_id: @resident.id, title: "storm-chr-#{@index}-#{@n}",
         start_year: day.year, start_month: day.month, start_day: day.day,
         start_hours: start_hour, start_minutes: 0, end_hours: start_hour + 1, end_minutes: 0 }, nil]
    end

    def request_common_house_delete(meal)
      id = @common_houses.shift
      return request_common_house_create(meal) + [:common_house_create] if id.nil?

      [:delete, "/api/v1/common-house-reservations/#{id}/delete", nil, nil]
    end

    def request_preview(_meal)
      [:get, "/api/v1/reconciliations/preview?cutoff=#{@plan.community.yesterday.iso8601}", nil, nil]
    end

    def request_settle(_meal)
      [:post, '/api/v1/reconciliations', { cutoff: @plan.community.yesterday.iso8601 }, nil]
    end
  end
end
