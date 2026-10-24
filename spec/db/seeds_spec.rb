# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'db/seeds.rb' do
  # Pins issue #63: db/seeds.rb must do nothing in the test environment.
  # `rails db:prepare` runs the seed file whenever it creates a database, so
  # without the guard every fresh test database starts with demo rows, and
  # the specs that expect an empty database fail on a clean checkout.
  it 'creates nothing in the test environment' do
    expect { Rails.application.load_seed }.not_to change(Community, :count).from(0)
  end

  # `bin/rails db:prepare` on a new development database loads
  # db/structure.sql and then runs this file, so it must work on a
  # database built from db/structure.sql alone. The test database is
  # built that way. The seed picks cooks and sign-ups at random, so this
  # fixes Ruby's random numbers to a value that once made it fail, and
  # puts back the old ones afterwards for the examples that follow.
  it 'fills a new database with the development data' do
    allow(Rails.env).to receive(:test?).and_return(false)
    previous = srand(1)

    expect { Rails.application.load_seed }.to change(Community, :count).from(0).to(1)
    expect(Reconciliation.count).to eq(1)
    expect(Meal.unreconciled).to exist
    # Rake runs a task once per process. A seed that ran billing:recalculate
    # left it marked as run, so a later spec's invoke did nothing (CI, seed
    # 60132, 2026-10-23).
    expect(Rake::Task.task_defined?('billing:recalculate') && Rake::Task['billing:recalculate'].already_invoked)
      .to be_falsey
  ensure
    srand(previous)
  end
end
