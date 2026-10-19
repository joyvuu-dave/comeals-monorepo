# frozen_string_literal: true

require 'rails_helper'

# bin/lib/staging_smoke_seed.rb, which bin/staging-rehearsal runs on the
# staging app with bin/rails runner. Here it runs in the test process
# against the test database, so SimpleCov counts its lines and branches
# with the rest of the suite (spec/simplecov_profile.rb covers bin/lib).
#
# The file is compiled once and run once per example. Loading it again
# for each example would not work: Ruby starts a file's coverage count
# again on every load, so only the last example would count.
RSpec.describe 'bin/lib/staging_smoke_seed.rb' do
  seed = RubyVM::InstructionSequence.compile_file(Rails.root.join('bin/lib/staging_smoke_seed.rb').to_s)

  let(:env) do
    { 'COMEALS_STAGING' => '1', 'SMOKE_EMAIL' => 'smoke@staging.invalid', 'SMOKE_PASSWORD' => 'made-up-password' }
  end
  let(:today) { Date.current }
  let!(:unit) { create(:unit, name: 'A1') }
  let!(:earlier_meal) { create(:meal, date: today + 100) }

  around do |example|
    saved = env.keys.index_with { ENV.fetch(it, nil) }
    env.each { |key, value| ENV[key] = value }
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  define_method(:run_seed) { seed.eval }

  # The seed stops with abort: a message on stderr and SystemExit.
  def a_refusal(message)
    raise_error(SystemExit).and output(/#{Regexp.escape(message)}/).to_stderr
  end

  it 'makes a resident who can log in and an open meal 120 days out, and prints its id' do
    create(:unit, name: 'B1')

    expect { run_seed }.to output(/\ASMOKE_MEAL_ID=\d+\n\z/).to_stdout

    resident = Resident.find_by!(email: 'smoke@staging.invalid')
    expect(resident).to have_attributes(name: 'Smoke Test', unit:, can_cook: true, vegetarian: false,
                                        birthday: Date.new(1990, 1, 1))
    expect(resident.authenticate('made-up-password')).to eq(resident)
    meal = Meal.find_by!(date: today + 120)
    expect(meal).to have_attributes(rotation: earlier_meal.rotation, closed: false, reconciliation_id: nil)
  end

  it 'gives the password of this rehearsal to a smoke resident left from an earlier one' do
    old = create(:resident, email: 'smoke@staging.invalid', name: 'Old Smoke', password: 'older-password')

    expect { run_seed }.to output.to_stdout

    expect(old.reload.name).to eq('Smoke Test')
    expect(old.authenticate('made-up-password')).to eq(old)
    expect(Resident.where(email: 'smoke@staging.invalid').count).to eq(1)
  end

  it 'takes the first free date from 120 days out' do
    create(:meal, date: today + 120, rotation: earlier_meal.rotation)

    expect { run_seed }.to output.to_stdout

    expect(Meal.exists?(date: today + 121)).to be(true)
  end

  it 'refuses on an app that is not staging' do
    ENV['COMEALS_STAGING'] = ''

    expect { run_seed }.to a_refusal('Refusing: COMEALS_STAGING is not set')
    expect(Resident.exists?(email: 'smoke@staging.invalid')).to be(false)
  end

  it 'refuses when the database has no units' do
    unit.destroy!

    expect { run_seed }.to a_refusal('Refusing: no units in the restored database')
  end

  it 'refuses when every date from 120 to 150 days out has a meal' do
    (120..150).each { create(:meal, date: today + it, rotation: earlier_meal.rotation) }

    expect { run_seed }.to a_refusal('Refusing: no free meal date between +120 and +150 days')
  end

  it 'refuses when no meal comes before the free date' do
    earlier_meal.destroy!

    expect { run_seed }.to a_refusal("Refusing: no meal before #{today + 120} to take a rotation from")
  end
end
