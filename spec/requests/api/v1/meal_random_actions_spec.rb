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
# validation, and Settlement's own rule that a meal needs a bill and an
# attendee to settle. A disagreement is either a rule the model misread,
# which is a documentation finding, or a write path that does not do what
# the rules say, which is a bug. Every failure message carries the seed
# and the step, so `MONEY_PROPERTY_SEED=n` reruns the one sequence.
RSpec.describe 'random action sequences against one meal, through the API' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:residents) do
    [2, 2, 2, 1, 0, 2].each_with_index.map do |multiplier, i|
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

  def noise = Reconciliation::ZERO_SUM_EPSILON

  # JSON, as the SPA sends it. A form-encoded empty bills list reaches the
  # controller as one empty string and answers 500 (noted 2026-09-09).
  def request(verb, path, resident, params = {})
    public_send(verb, path, params: params.merge(token: resident.keys.first.token), as: :json)
    expect(response.status).to be < 500, "#{where}: #{verb.upcase} #{path} answered #{response.status}"
    [response.status, response.parsed_body]
  end

  def answer = "answered #{response.status}: #{response.parsed_body['message']}"

  def fresh_model
    { attendance: {}, guests: {}, bills: {}, closed: false, max: nil, settled: false }
  end

  def attendees_count(model) = model[:attendance].size + model[:guests].size

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
    status, body = request(:post, "/api/v1/meals/#{meal.id}/residents/#{host.id}/guests", host, vegetarian: false)
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

  def set_bills(model, rng)
    cooks = residents.sample(rng.rand(model[:bills].empty? ? (1..3) : (0..3)), random: rng)
    bills = cooks.map do |cook|
      no_cost = rng.rand < 0.2
      cents = no_cost ? 0 : rng.rand(0..999_999)
      { resident_id: cook.id, amount: "#{cents / 100}.#{format('%02d', cents % 100)}", no_cost: no_cost }
    end
    status, = request(:patch, "/api/v1/meals/#{meal.id}/bills", residents.first, bills: bills)
    if model[:settled]
      expect(status).to eq(400), "#{where}: bills after settlement answered #{status}"
    else
      expect(status).to eq(200), "#{where}: bills answered #{status}"
      model[:bills] = bills.to_h { |b| [b[:resident_id], { amount: BigDecimal(b[:amount]), no_cost: b[:no_cost] }] }
    end
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
    elsif model[:bills].any?
      # The code's rule (Meal.settleable_by): a bill and a past date. Not an
      # attendee, although MODELS.md says a bill on a meal nobody ate has no
      # financial effect. Found by seed 13 on 2026-09-09; the rule is open.
      expect(status).to eq(201), "#{where}: settling a meal with a bill answered #{status}: #{response.body}"
      model[:settled] = true
    else
      expect(status).to eq(400), "#{where}: settling with nothing to settle answered #{status}"
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
      expect((a - e).abs).to be <= noise,
                             "#{where}: #{label} differ for resident #{id}: #{a.to_s('F')} vs #{e.to_s('F')}"
    end
  end

  def expect_ledger_sound(model)
    rows = Meal.preload(:bills, :meal_residents, :guests).find(meal.id)
    lines = MealLedger.new([rows]).lines
    expect(lines.sum(BigDecimal('0'), &:amount).abs).to be <= noise, "#{where}: lines do not sum to zero"
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
