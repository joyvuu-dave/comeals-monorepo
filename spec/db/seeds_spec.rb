# frozen_string_literal: true

require 'rails_helper'

# Pins issue #63: db/seeds.rb must do nothing in the test environment.
# `rails db:prepare` runs the seed file whenever it creates a database, so
# without the guard every fresh test database starts with demo rows, and
# the specs that expect an empty database fail on a clean checkout.
RSpec.describe 'db/seeds.rb' do
  it 'creates nothing in the test environment' do
    expect { Rails.application.load_seed }.not_to change(Community, :count).from(0)
  end
end
