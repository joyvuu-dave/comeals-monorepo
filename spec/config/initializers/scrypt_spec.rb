# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/initializers/scrypt.rb' do
  it 'hashes passwords at the smallest SCrypt cost in the test environment' do
    expect(ScryptCost.for(ActiveSupport::EnvironmentInquirer.new('test'))).to eq('10$8$1$')
  end

  it "leaves the cost to SCrypt's own measure of the machine everywhere else" do
    expect(ScryptCost.for(ActiveSupport::EnvironmentInquirer.new('production'))).to be_nil
  end

  it 'is the cost a resident password gets in the test environment, and the password still checks' do
    resident = build(:resident, password: 'a password')
    expect(SCrypt::Password.new(resident.password_digest).cost).to eq('10$8$1$')
    expect(resident.authenticate('a password')).to eq(resident)
    expect(resident.authenticate('another')).to be(false)
  end
end
