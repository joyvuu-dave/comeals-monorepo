# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rails db:seed command (or created alongside the database with db:setup).
#
# Examples:
#
#   movies = Movie.create([{ name: 'Star Wars' }, { name: 'Lord of the Rings' }])
#   Character.create(name: 'Luke', movie: movies.first)

# The test database must never get these rows. RSpec expects an empty
# database, and the browser suites load their own deterministic seeds
# (lib/tasks/test/seed_integration.rake, tests/admin/seed.rb). db:prepare
# runs this file whenever it creates a database, so this guard — not the
# caller's choice of rake task — is what keeps a fresh test database
# empty (#63).
return if Rails.env.test?

start = Time.zone.now

# Community (singleton). timezone is explicit because the DB column has no
# default — operators on a real deploy pick one via the ActiveAdmin form.
# Dev seed pins Pacific so fixture timestamps render consistently.
community = Community.first || Community.create!(name: 'Patches Way',
                                                 cap: BigDecimal('2.50'),
                                                 timezone: 'America/Los_Angeles')

Rails.logger.debug '1 Community created'

# Phone numbers. Every number here is from a range reserved for fiction
# (US 555-01XX, the UK 020 7946 09XX drama range, the French 01 99 00 XX XX
# test range), so no seed row ever holds a real person's number — yet
# libphonenumber accepts them all as valid, which the model requires.
# Most adults get a US number, a few get an international one to show the
# E.164 path works past +1, and a few get none, because a blank phone is a
# state every screen must handle. Inputs are typed the way people type
# them ("510-555-0123", "+44 20 7946 0958"); the model normalizes each to
# E.164 before saving.
phone_counter = 0
next_phone = lambda do
  phone_counter += 1
  case phone_counter % 9
  when 3 then format('+44 20 7946 09%<n>02d', n: phone_counter)        # UK
  when 6 then format('+33 1 99 00 %<n>02d 10', n: phone_counter)       # France
  when 8 then nil                                                      # no phone given
  else
    area = %w[212 310 415 510 617 773 808].fetch(phone_counter % 7)
    format('%<area>s-555-01%<n>02d', area: area, n: phone_counter)
  end
end

# AdminUser. Two of them, because SuperuserAdapter has two admin tiers: a
# superuser may do anything, and a plain admin may do everything except write
# on the money path. Seeding one of each makes both sides of that boundary
# something you can log in and look at. One US phone and one UK phone, so
# both admin forms show a normalized number.
AdminUser.create!(email: 'joslyn@email.com', password: 'password', password_confirmation: 'password',
                  community: community, superuser: true, phone: '(510) 555-0199')
AdminUser.create!(email: 'reader@email.com', password: 'password', password_confirmation: 'password',
                  community: community, phone: '+44 20 7946 0999')

Rails.logger.debug { "#{community.admin_users.count} AdminUser created" }

# Units / Residents
('A'..'Z').to_a.each_with_index do |letter, index|
  next if %w[O I].include?(letter)

  unit = Unit.create!(name: letter, community: community)
  if (index % 5).zero?
    child_year = ((Time.zone.today.year - 10)..(Time.zone.today.year - 1)).to_a.sample
    child_birthday = Date.new(child_year, (1..12).to_a.sample, (1..28).to_a.sample)
    Resident.create!(name: "#{Faker::Name.first_name} #{Faker::Name.last_name}",
                     multiplier: 1, unit: unit, community: community,
                     password: '', birthday: child_birthday)
  end
  adult_year = ((Time.zone.today.year - 90)..(Time.zone.today.year - 20)).to_a.sample
  adult_birthday = Date.new(adult_year, (1..12).to_a.sample, (1..28).to_a.sample)
  Resident.create!(name: "#{Faker::Name.first_name} #{Faker::Name.last_name}",
                   multiplier: 2, unit: unit, email: Faker::Internet.email,
                   community: community, password: 'password',
                   birthday: adult_birthday, phone: next_phone.call)
  next unless index.even?

  veg_year = ((Time.zone.today.year - 90)..(Time.zone.today.year - 20)).to_a.sample
  veg_birthday = Date.new(veg_year, (1..12).to_a.sample, (1..28).to_a.sample)
  Resident.create!(name: "#{Faker::Name.first_name} #{Faker::Name.last_name}",
                   multiplier: 2, unit: unit, email: Faker::Internet.email,
                   community: community, password: 'password',
                   vegetarian: true, birthday: veg_birthday, phone: next_phone.call)
end

Rails.logger.debug { "#{community.units.count} Units created" }

# Give 3 Residents the same First Name
first_name = Faker::Name.first_name
Resident.where(id: Resident.where(multiplier: 2).pluck(:id).shuffle.take(3)).find_each do |resident|
  resident.update!(name: "#{first_name} #{Faker::Name.last_name}")
end

# Make 1 (adult) Resident have a simple email address and matching name
Resident.where(multiplier: 2).first.update!(email: 'bowen@email.com', name: 'Bowen Riddle')

Rails.logger.debug { "#{community.residents.count} Residents created" }

# Meals (will be reconciled)
community.meal_schedule.dates_between(26.weeks.ago.to_date, 8.weeks.ago.to_date).each do |date|
  Meal.create!(date: date, community: community)
end

Rails.logger.debug { "#{community.meals.count} Meals created" }

# MealResidents & Guests
Meal.find_each do |meal|
  next if meal.date > Time.zone.today + 7

  Resident.all.shuffle[0..(Random.rand(8..21))].each_with_index do |resident, index|
    if (index % 10).zero?
      num = Random.rand(1..3)
      if num == 1
        Guest.create!(multiplier: 2,
                      vegetarian: true,
                      resident_id: resident.id,
                      meal_id: meal.id)
      else
        Guest.create!(multiplier: 2,
                      vegetarian: false,
                      resident_id: resident.id,
                      meal_id: meal.id)
      end
    elsif (index % 13).zero?
      MealResident.create!(resident_id: resident.id,
                           meal_id: meal.id,
                           multiplier: resident.multiplier,
                           community: community,
                           late: true)
    else
      MealResident.create!(resident_id: resident.id,
                           meal_id: meal.id,
                           multiplier: resident.multiplier,
                           community: community)
    end
  end
end

Rails.logger.debug { "#{community.guests.count} Guests created" }
Rails.logger.debug { "#{community.meal_residents.count} MealResidents created" }

# Real receipts are rarely round numbers. Most seeded bills get a cents
# part from this list — mostly primes, which no attendee count divides
# evenly — so dev data makes the division and rounding code work on the
# kind of numbers real receipts have. Zero and 50 stay in the list so
# round amounts still appear too.
awkward_cents = [0, 0, 50, 1, 3, 7, 13, 17, 19, 23, 29, 31, 37, 41,
                 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97]
bill_amount = lambda do |dollars|
  BigDecimal(format('%<dollars>d.%<cents>02d', dollars: dollars.to_a.sample, cents: awkward_cents.sample))
end

# Bills — two cooks per meal, covering every shape a real meal takes:
# both cooks entered a cost; one entered while the other declared no
# cost (two cooks, one shopper); one entered while the other never put
# anything in. In this batch that last shape settles at zero when the
# reconciliation sweeps it — the outcome the close-time question now
# exists to prevent.
Meal.all.each_with_index do |meal, index|
  next if meal.date > Time.zone.today + 14

  ids = Resident.pluck(:id).sample(2)
  Bill.create!(meal_id: meal.id, resident_id: ids[0],
               amount: bill_amount.call(25..65), community: community)
  case index % 3
  when 0
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: BigDecimal('0'), no_cost: true, community: community)
  when 1
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: BigDecimal('0'), community: community)
  else
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: bill_amount.call(35..75), community: community)
  end
end

Rails.logger.debug { "#{community.bills.count} Bills created" }

# Reconciliation — sweeps the first batch of meals (26..8 weeks ago).
# end_date must be strictly in the past (issue #3): a meal from a day that
# is not over must not be settled. The cutoff sits on the first batch's
# boundary so the sweep takes exactly that batch.
Reconciliation.create!(community: community, date: Time.zone.today, end_date: 8.weeks.ago.to_date)
Rails.logger.debug { "#{community.reconciliations.count} Reconciliation created" }

# Meals (will not be reconciled)
community.meal_schedule.dates_between(7.weeks.ago.to_date, 26.weeks.from_now.to_date).each do |date|
  Meal.create!(date: date, community: community)
end

# MealResidents & Guests for the unreconciled batch. Skip reconciled meals
# because MealResident/Guest enforce immutability via before_save callbacks
# (see app/models/meal_resident.rb, guest.rb) — writing to a reconciled meal
# raises RecordNotSaved.
Meal.unreconciled.find_each do |meal|
  next if meal.date > Time.zone.today + 7

  Resident.all.shuffle[0..(Random.rand(8..21))].each_with_index do |resident, index|
    if (index % 10).zero?
      num = Random.rand(1..3)
      if num == 1
        Guest.create!(multiplier: 2,
                      vegetarian: true,
                      resident_id: resident.id,
                      meal_id: meal.id)
      else
        Guest.create!(multiplier: 2,
                      vegetarian: false,
                      resident_id: resident.id,
                      meal_id: meal.id)
      end
    elsif (index % 13).zero?
      MealResident.create(resident_id: resident.id,
                          meal_id: meal.id,
                          multiplier: resident.multiplier,
                          community: community,
                          late: true)
    else
      MealResident.create(resident_id: resident.id,
                          meal_id: meal.id,
                          multiplier: resident.multiplier,
                          community: community)
    end
  end
end

Rails.logger.debug { "#{community.guests.count} Guests created" }
Rails.logger.debug { "#{community.meal_residents.count} MealResidents created" }

# Bills on the unreconciled batch — Bill also enforces reconciled-meal
# immutability (see app/models/bill.rb). Same shapes as the reconciled
# batch, plus meals where nobody has signed up to cook yet. A "never
# entered" cook on a closed meal is the pending state the meal page
# displays.
Meal.unreconciled.each_with_index do |meal, index|
  next if meal.date > Time.zone.today + 14

  ids = Resident.pluck(:id).sample(2)
  case index % 4
  when 0
    Bill.create!(meal_id: meal.id, resident_id: ids[0],
                 amount: bill_amount.call(25..65), community: community)
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: BigDecimal('0'), no_cost: true, community: community)
  when 1
    Bill.create!(meal_id: meal.id, resident_id: ids[0],
                 amount: bill_amount.call(25..65), community: community)
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: BigDecimal('0'), community: community)
  when 2
    Bill.create!(meal_id: meal.id, resident_id: ids[0],
                 amount: bill_amount.call(25..65), community: community)
    Bill.create!(meal_id: meal.id, resident_id: ids[1],
                 amount: bill_amount.call(35..75), community: community)
  end
  # index % 4 == 3: no cooks yet.
end

Rails.logger.debug { "#{community.bills.count} Bills created" }

# Set description
Meal.find_each do |meal|
  next if meal.date > Time.zone.today + 14

  meal.update!(description: "#{Faker::Food.dish}, #{Faker::Food.ingredient}, and #{Faker::Dessert.flavor} #{Faker::Dessert.variety}")
end

# Set Max
Meal.all.each_with_index do |meal, index|
  if (meal.date < Time.zone.today && index.even?) || meal.date.between?(Time.zone.today, Time.zone.today + 3)
    meal.update!(closed: true)
    meal.update!(max: meal.attendees_count + rand(1..4))
  end
end

Rails.logger.debug { "#{community.meals.count} Meals created (#{community.meals.unreconciled.count} unreconciled)" }

# Create Rotations
community.auto_create_rotations

Rails.logger.debug { "#{community.rotations.count} Rotations created" }

# Event
Time.zone = community.timezone
today = Time.zone.today
Event.create!(community: community, title: 'HOA Meeting',
              start_date: Time.zone.local(today.year, today.month, today.day, 20, 0, 0),
              end_date: Time.zone.local(today.year, today.month, today.day, 21, 30, 0))
Event.create!(community: community, title: "Swan's Anniversary",
              start_date: Time.zone.local(Time.zone.now.year, Time.zone.now.month, 15, 1, 0, 0), allday: true)

Rails.logger.debug { "#{community.events.count} Event#{'s' unless Event.one?} created" }

# GuestRoomReservation
Time.zone = community.timezone
GuestRoomReservation.create!(community: community,
                             resident_id: Resident.adult.pluck(:id).sample,
                             date: Time.zone.today)

Rails.logger.debug do
  "#{community.guest_room_reservations.count} GuestRoomReservation#{'s' unless GuestRoomReservation.one?} created"
end

# CommonHouseReservation
Time.zone = community.timezone
tomorrow = Date.tomorrow
CommonHouseReservation.create!(
  community: community,
  resident_id: Resident.adult.pluck(:id).sample,
  start_date: Time.zone.local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 30, 0),
  end_date: Time.zone.local(tomorrow.year, tomorrow.month, tomorrow.day, 14, 0, 0)
)

Rails.logger.debug do
  "#{community.common_house_reservations.count} CommonHouseReservation#{'s' unless CommonHouseReservation.one?} created"
end

# Balances cache — in production the daily billing:recalculate task
# refreshes it. A fresh dev database should not have to wait for 3am.
Rails.application.load_tasks unless Rake::Task.task_defined?('billing:recalculate')
Rake::Task['billing:recalculate'].invoke

Rails.logger.debug { "#{ResidentBalance.count} ResidentBalances computed" }

# Ledger check runs — the Ledger Checks admin page needs rows in every
# shape it can show. Three nights of history:
#
#   two nights ago  the check crashed        (staged)
#   last night      it found a mismatch      (staged)
#   tonight         it passes                (real)
#
# The passing run is real: LedgerVerification runs here against the
# reconciliation seeded above, exactly as it does nightly in production.
# The other two cannot be produced honestly — settled data refuses the
# writes that would cause a mismatch — so they are staged records of
# nights that never happened, using the real reconciliation and real
# resident ids so every link on the page goes somewhere. The story the
# three rows tell is the runbook's: a mismatch was found, the data was
# repaired, and the next run passed.
two_nights_ago = 2.days.ago.change(hour: 3)
LedgerCheckRun.create!(
  started_at: two_nights_ago,
  finished_at: two_nights_ago + 2.seconds,
  reconciliations_checked: 0,
  details: [],
  error: 'PG::ConnectionBad: server closed the connection unexpectedly'
)

reconciliation = Reconciliation.first
drifted = reconciliation.reconciliation_balances.order(:resident_id).limit(2)
last_night = 1.day.ago.change(hour: 3)
LedgerCheckRun.create!(
  started_at: last_night,
  finished_at: last_night + 3.seconds,
  reconciliations_checked: 1,
  mismatch_count: 1,
  details: [
    {
      reconciliation_id: reconciliation.id,
      date: reconciliation.date.to_s,
      check: 'recompute',
      # Amounts are strings, never JSON numbers — same rule as the verifier.
      differences: drifted.map do |balance|
        { resident_id: balance.resident_id,
          stored: balance.amount.to_s('F'),
          source: (balance.amount + BigDecimal('1.5')).to_s('F') }
      end
    }
  ]
)

LedgerVerification.call

Rails.logger.debug { "#{LedgerCheckRun.count} LedgerCheckRuns created (1 real, 2 staged)" }

# Analytics
Rails.logger.debug { "Seed records created in #{Time.zone.now - start}s" }
