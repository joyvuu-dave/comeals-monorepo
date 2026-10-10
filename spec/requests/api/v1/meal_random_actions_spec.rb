# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/oracle/plain_ledger')

# Random sequences of writes against one meal, sent through the API the
# way the app sends them, with a model beside them of what the rules say
# should happen. After every request the spec checks three things:
#
#   1. the status the model predicted (allowed or refused, and why);
#   2. the rows: attendance, guests, bills, closed, max, all equal to the
#      model, so a refused write changed nothing and an allowed one
#      changed exactly what it said;
#   3. the ledger: the meal's lines sum to zero and agree with the plain
#      ledger, and once settled the stored charges agree too and every
#      later write is refused.
#
# The rules the model encodes are the ones in the concerns:
# ClosedMealAttendanceFreeze (no new attendance on a closed meal unless a
# max leaves spots, and only rows added after the close can be removed),
# ReconciledMealImmutability (nothing changes after settlement), the max
# validation, and Settlement's own rule that a meal needs a bill, and
# someone with a price or no money on the receipts, to settle. A
# disagreement is either a rule the model misread, which is a
# documentation finding, or a write path that does not do what the rules
# say, which is a bug. Every failure message carries the seed and the
# step, so `MONEY_PROPERTY_SEED=n` reruns the one sequence.
RSpec.describe 'random action sequences against one meal, through the API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # Each resident's price. The one at 0 eats free.
  let(:prices) { [2, 2, 2, 1, 0, 2] }
  let(:residents) do
    prices.each_with_index.map do |multiplier, i|
      create(:resident, community: community, unit: unit, multiplier: multiplier, can_reconcile: i.zero?)
    end
  end
  let(:meal) { create(:meal, community: community, date: Date.yesterday) }
  # "seed 3, step 7 (signup)": every failure message starts with it.
  let(:where) { +'' }

  # 1400 requests from one address in under a minute is exactly what the
  # API throttle (600 a minute, config/initializers/rack_attack.rb) is for.
  # Off for this file, and the counters cleared after, so the specs that
  # run next do not inherit a full window.
  around do |example|
    Rack::Attack.enabled = false
    example.run
  ensure
    Rack::Attack.enabled = true
    Rails.cache.clear
  end

  # JSON, as the SPA sends it. (A form-encoded empty bills list reaches the
  # controller as one empty string; it answered 500 until 2026-09-10 and is
  # refused with 400 now, see update_bills_spec.rb.)
  def request(verb, path, resident, params = {}, headers = {})
    public_send(verb, path, params: params.merge(token: resident.keys.first.token), headers: headers, as: :json)
    expect(response.status).to be < 500, "#{where}: #{verb.upcase} #{path} answered #{response.status}"
    [response.status, response.parsed_body]
  end

  def answer = "answered #{response.status}: #{response.parsed_body['message']}"

  def fresh_model
    { attendance: {}, guests: {}, bills: {}, closed: false, max: nil, settled: false }
  end

  def attendees_count(model) = model[:attendance].size + model[:guests].size

  # Someone with a price ate: a resident whose multiplier is above 0, or
  # any guest, because the API adds a guest at the adult price.
  def someone_to_charge?(model)
    model[:guests].any? || residents.zip(prices).any? { |r, price| price.positive? && model[:attendance].key?(r.id) }
  end

  def spots_left?(model)
    !model[:closed] || (model[:max] && attendees_count(model) < model[:max])
  end

  def removable?(model, row) = !model[:closed] || row[:after_close]

  # --- the actions ---------------------------------------------------------

  def signup(model, rng)
    resident = residents.sample(random: rng)
    late = rng.rand < 0.3
    status, = request(:post, "/api/v1/meals/#{meal.id}/residents/#{resident.id}", resident,
                      late: late, vegetarian: false)
    if model[:settled]
      expect(status).to eq(400), "#{where}: signup after settlement answered #{status}"
    elsif model[:attendance].key?(resident.id)
      expect(status).to eq(200), "#{where}: re-signup of an attendee answered #{status}"
      model[:attendance][resident.id][:late] = late
    elsif spots_left?(model)
      expect(status).to eq(200), "#{where}: signup with spots left answered #{status}"
      model[:attendance][resident.id] = { late: late, after_close: model[:closed] }
    else
      expect(status).to eq(400), "#{where}: signup on a full closed meal answered #{status}"
    end
  end

  def leave(model, rng)
    resident = residents.sample(random: rng)
    row = model[:attendance][resident.id]
    status, = request(:delete, "/api/v1/meals/#{meal.id}/residents/#{resident.id}", resident)
    if model[:settled]
      expect(status).to eq(400), "#{where}: leaving after settlement answered #{status}"
    elsif row.nil?
      expect(status).to eq(404), "#{where}: leaving without a row #{answer}"
    elsif removable?(model, row)
      expect(status).to eq(200), "#{where}: leaving an open meal answered #{status}"
      model[:attendance].delete(resident.id)
    else
      expect(status).to eq(400), "#{where}: leaving a closed meal answered #{status}"
    end
  end

  def toggle(model, rng)
    resident = residents.sample(random: rng)
    late = rng.rand < 0.5
    status, = request(:patch, "/api/v1/meals/#{meal.id}/residents/#{resident.id}", resident, late: late)
    if model[:settled]
      expect(status).to eq(400), "#{where}: toggling after settlement answered #{status}"
    elsif model[:attendance][resident.id].nil?
      expect(status).to eq(404), "#{where}: toggling without a row #{answer}"
    else
      expect(status).to eq(200), "#{where}: toggling answered #{status}"
      model[:attendance][resident.id][:late] = late
    end
  end

  def add_guest(model, rng)
    host = residents.sample(random: rng)
    status, body = request(:post, "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests", host,
                           { vegetarian: false }, IdempotencyKey.header)
    if model[:settled]
      expect(status).to eq(400), "#{where}: guest after settlement answered #{status}"
    elsif spots_left?(model)
      expect(status).to eq(200), "#{where}: guest with spots left answered #{status}"
      model[:guests][body.fetch('id')] = { host: host.id, after_close: model[:closed] }
    else
      expect(status).to eq(400), "#{where}: guest on a full closed meal answered #{status}"
    end
  end

  def remove_guest(model, rng)
    guest_id, row = model[:guests].to_a.sample(random: rng) || [0, nil]
    host = row ? residents.find { |r| r.id == row[:host] } : residents.first
    status, = request(:delete, "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests/#{guest_id}", host)
    if model[:settled]
      expect(status).to eq(400), "#{where}: removing a guest after settlement answered #{status}"
    elsif row.nil?
      expect(status).to eq(404), "#{where}: removing a guest that is not there #{answer}"
    elsif removable?(model, row)
      expect(status).to eq(200), "#{where}: removing a guest answered #{status}"
      model[:guests].delete(guest_id)
    else
      expect(status).to eq(400), "#{where}: removing a guest from a closed meal answered #{status}"
    end
  end

  # A bills save the way the page sends it (#135): one edit for each cook
  # whose bill changes, with the bill the model says is stored as `from`.
  # The cooks picked here become the meal's cooks, so every save mixes
  # adds, changes and removes. Now and then one edit carries a `from` that
  # is not stored, the way a page that missed another page's save would
  # send it: the whole save must be refused and write nothing. And now and
  # then a save that went through is sent again with its Idempotency-Key,
  # the way a page resends after no answer: it must change nothing.
  def set_bills(model, rng)
    cooks = residents.sample(rng.rand(model[:bills].empty? ? (1..3) : (0..3)), random: rng)
    wanted = cooks.to_h do |cook|
      no_cost = rng.rand < 0.2
      cents = no_cost ? 0 : rng.rand(0..999_999)
      [cook.id, { amount: BigDecimal(cents) / 100, no_cost: no_cost }]
    end
    edits = BillEdits.between(model[:bills], wanted)
    stale = edits.any? { |edit| edit[:from] } && rng.rand < 0.15
    edits = with_a_wrong_from(edits, rng) if stale
    key = BillEdits.key_header
    status, body = request(:patch, "/api/v1/meals/#{meal.id}/bills", residents.first, { edits: edits }, key)
    return unless bills_saved?(model, status, body, stale)

    model[:bills] = wanted
    resend(edits, key) if rng.rand < 0.2
  end

  def bills_saved?(model, status, body, stale)
    if model[:settled]
      expect(status).to eq(400), "#{where}: bills after settlement answered #{status}"
    elsif stale
      expect([status, body['type']]).to eq([409, 'stale']), "#{where}: a stale bills save #{answer}"
    else
      expect(status).to eq(200), "#{where}: bills #{answer}"
      return true
    end
    false
  end

  # Flips no_cost in one edit's `from`, so it is neither the stored bill
  # nor the edit's `to`.
  def with_a_wrong_from(edits, rng)
    index = edits.each_index.select { |i| edits[i][:from] }.sample(random: rng)
    edits.each_with_index.map do |edit, i|
      i == index ? edit.merge(from: edit[:from].merge(no_cost: !edit[:from][:no_cost])) : edit
    end
  end

  def resend(edits, key)
    status, body = request(:patch, "/api/v1/meals/#{meal.id}/bills", residents.first, { edits: edits }, key)
    expect([status, body['type']]).to eq([200, 'replayed']), "#{where}: the same bills save sent again #{answer}"
  end

  def close(model, _rng)
    status, = request(:patch, "/api/v1/meals/#{meal.id}/closed", residents.first, closed: true)
    if model[:settled]
      expect(status).to eq(400), "#{where}: closing after settlement answered #{status}"
    else
      expect(status).to eq(200), "#{where}: closing answered #{status}"
      unless model[:closed]
        model[:closed] = true
        (model[:attendance].values + model[:guests].values).each { |row| row[:after_close] = false }
      end
    end
  end

  def reopen(model, _rng)
    status, = request(:patch, "/api/v1/meals/#{meal.id}/closed", residents.first, closed: false)
    if model[:settled]
      expect(status).to eq(400), "#{where}: reopening after settlement answered #{status}"
    else
      expect(status).to eq(200), "#{where}: reopening answered #{status}"
      model[:closed] = false
      model[:max] = nil
    end
  end

  def set_max(model, rng)
    max = rng.rand(0..8)
    status, = request(:patch, "/api/v1/meals/#{meal.id}/max", residents.first, max: max)
    if model[:settled]
      expect(status).to eq(400), "#{where}: max after settlement answered #{status}"
    elsif !model[:closed] || max < attendees_count(model)
      expect(status).to eq(400), "#{where}: max #{max} on an open or fuller meal answered #{status}"
    else
      expect(status).to eq(200), "#{where}: max #{max} answered #{status}"
      model[:max] = max
    end
  end

  def settle(model, _rng)
    reconciler = residents.first
    post '/api/v1/reconciliations', params: { cutoff: Date.yesterday.to_s },
                                    headers: { 'Authorization' => "Bearer #{reconciler.keys.first.token}" }
    status = response.status
    expect(status).to be < 500, "#{where}: settling answered #{status}"
    if model[:settled]
      expect(status).to eq(400), "#{where}: settling twice answered #{status}"
    elsif model[:bills].any? && (someone_to_charge?(model) || model[:bills].values.none? do |b|
      b[:amount].positive? && !b[:no_cost]
    end)
      # Meal.settleable_by: a bill, a past date, and someone to charge or
      # nothing owed. A receipt with money is held back when nobody signed
      # up (seed 13 found it was settled and frozen, 2026-09-09; changed
      # 2026-09-10) or when only the free resident did (#94, 2026-10-09).
      expect(status).to eq(201), "#{where}: settling answered #{status}: #{response.body}"
      model[:settled] = true
    else
      expect(status).to eq(400), "#{where}: settling with nothing to settle, or only a receipt nobody can be " \
                                 "charged for, answered #{status}"
    end
  end

  def action_weights
    { signup: 5, leave: 3, toggle: 1, add_guest: 3, remove_guest: 2, set_bills: 4,
      close: 1, reopen: 1, set_max: 1, settle: 1 }
  end

  # From step 22 the sequence is steered to the settled half: a bill
  # whenever there is none, then the settlement from step 24 on.
  def pick_action(rng, model, step)
    if step >= 22 && !model[:settled]
      return :set_bills if model[:bills].empty?
      return :settle if step >= 24
    end

    action_weights.flat_map { |name, weight| [name] * weight }.sample(random: rng)
  end

  # --- the checks after every step -----------------------------------------

  def expect_rows_to_match(model)
    rows = meal.reload
    expect_people_to_match(rows, model)
    bills = rows.bills.to_h { |b| [b.resident_id, { amount: b.amount, no_cost: b.no_cost }] }
    expect(bills).to eq(model[:bills]), "#{where}: bill rows"
    expect(rows.closed).to eq(model[:closed]), "#{where}: closed"
    expect(rows.max).to eq(model[:max]), "#{where}: max"
    expect(rows.reconciled?).to eq(model[:settled]), "#{where}: reconciled"
  end

  def expect_people_to_match(rows, model)
    attendance = rows.meal_residents.to_h { |a| [a.resident_id, a.late] }
    expect(attendance).to eq(model[:attendance].transform_values { |r| r[:late] }), "#{where}: attendance rows"
    guests = rows.guests.to_h { |g| [g.id, g.resident_id] }
    expect(guests).to eq(model[:guests].transform_values { |r| r[:host] }), "#{where}: guest rows"
  end

  def expect_close(actual, expected, label)
    (actual.keys | expected.keys).each do |id|
      a = actual.fetch(id, BigDecimal('0'))
      e = expected.fetch(id, BigDecimal('0'))
      expect(a).to eq(e), "#{where}: #{label} differ for resident #{id}: #{a.to_s('F')} vs #{e.to_s('F')}"
    end
  end

  def expect_ledger_sound(model)
    rows = Meal.preload(:bills, :meal_residents, :guests).find(meal.id)
    lines = MealLedger.new([rows]).lines
    expect(lines.sum(BigDecimal('0'), &:amount)).to eq(0), "#{where}: lines do not sum to zero"
    net = lines.group_by(&:resident_id).transform_values { |l| l.sum(BigDecimal('0'), &:amount) }
    expect_close(net, PlainLedger.net_by_meal([RandomLedger.plain(rows)]).transform_keys(&:last), 'ledger and oracle')
    return unless model[:settled]

    expect_close(MealCharge.where(meal_id: meal.id).group(:resident_id).sum(:amount), net, 'stored charges and rows')
  end

  seeds = ENV['MONEY_PROPERTY_SEED'] ? [Integer(ENV.fetch('MONEY_PROPERTY_SEED'))] : (1..40).to_a

  seeds.each do |seed|
    it "holds for sequence #{seed}" do
      rng = Random.new(seed)
      model = fresh_model
      residents
      meal
      35.times do |step|
        action = pick_action(rng, model, step)
        where.replace("seed #{seed}, step #{step + 1} (#{action})")
        public_send(action, model, rng)
        expect_rows_to_match(model)
        expect_ledger_sound(model)
      end
      expect(model[:settled]).to be(true),
                                 "seed #{seed}: the sequence never settled, so the immutable half was not exercised"
    end
  end
end
