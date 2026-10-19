# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/initializers/devise.rb' do
  it 'hashes passwords with cost 1 in the test environment' do
    expect(DevisePasswordStretches.for(ActiveSupport::EnvironmentInquirer.new('test'))).to eq(1)
  end

  it "hashes passwords with bcrypt's default cost everywhere else" do
    expect(DevisePasswordStretches.for(ActiveSupport::EnvironmentInquirer.new('production'))).to eq(11)
  end

  it 'is what Devise was given at boot' do
    expect(Devise.stretches).to eq(1)
  end
end
