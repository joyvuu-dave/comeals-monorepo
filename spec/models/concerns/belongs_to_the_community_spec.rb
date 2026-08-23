# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BelongsToTheCommunity do
  let(:community) { create(:community) }

  it 'is included by every model with a community_id column except AdminUser' do
    Rails.application.eager_load!
    with_column = ApplicationRecord.descendants.select { |model| model.column_names.include?('community_id') }
    expect(with_column.map(&:name).sort).to eq(%w[AdminUser Bill CommonHouseReservation Event
                                                  GuestRoomReservation Meal MealResident Reconciliation
                                                  Resident Rotation Unit])
    expect(with_column.reject { |model| model.include?(described_class) }).to eq([AdminUser])
  end

  it 'fills in the one community when the caller leaves it out' do
    community
    unit = Unit.new(name: 'A-1')

    expect(unit).to be_valid
    expect(unit.community).to eq(community)
  end

  it 'keeps a community the caller did set' do
    unit = Unit.new(name: 'A-1', community: community)
    allow(Community).to receive(:instance).and_raise('must not be called')

    expect(unit).to be_valid
    expect(unit.community).to eq(community)
  end

  it 'raises when no community exists yet, instead of saving an orphan row' do
    expect(Community.count).to eq(0)

    expect { Unit.new(name: 'A-1').valid? }.to raise_error(RuntimeError, /No Community record exists/)
  end
end
