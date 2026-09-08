# frozen_string_literal: true

require 'rails_helper'

# Every model ActiveAdmin can sort or filter names the columns Ransack may
# touch. The lists are written by hand, so one can drift from its table (a
# renamed column stays listed and the next sort by it raises) or grow a
# secret (a password digest or a reset token would become filterable).
RSpec.describe ApplicationRecord, '.ransackable_attributes' do
  let(:secret_columns) { %w[password_digest encrypted_password reset_password_token] }

  before { Rails.application.eager_load! }

  def models_with_a_list
    described_class.descendants.select do |model|
      !model.abstract_class? && model.singleton_class.method_defined?(:ransackable_attributes, false)
    end
  end

  it 'is written on every model with an admin page' do
    expect(models_with_a_list.map(&:name)).to include(
      'AdminUser', 'Bill', 'CommonHouseReservation', 'Community', 'Event', 'GuestRoomReservation', 'JobRun',
      'LedgerCheckRun', 'Meal', 'MealCharge', 'Reconciliation', 'Resident', 'Rotation', 'Unit'
    )
  end

  it 'names only real columns, so a sort can never raise' do
    models_with_a_list.each do |model|
      unknown = model.ransackable_attributes - model.column_names
      expect(unknown).to be_empty, "#{model.name} lists #{unknown.inspect}, which are not columns"
    end
  end

  it 'never lists a secret' do
    models_with_a_list.each do |model|
      leaked = model.ransackable_attributes & secret_columns
      expect(leaked).to be_empty, "#{model.name} lists #{leaked.inspect}"
    end
  end
end
