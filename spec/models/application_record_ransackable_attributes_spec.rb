# frozen_string_literal: true

require 'rails_helper'

# Every model ActiveAdmin can sort or filter names the columns Ransack may
# touch, and AdminOrderClause reads the same list for ?order=. The lists
# are written by hand, so one can drift from its table (a renamed column
# stays listed and the next sort by it raises) or grow a secret (a
# password digest or a reset token would become filterable and sortable).
RSpec.describe ApplicationRecord do
  describe '.ransackable_attributes' do
    # The columns ActiveAdmin keeps off every page and out of every CSV.
    # spec/requests/admin/secret_columns_spec.rb fails when a column named
    # like a credential is missing from it.
    let(:secret_columns) { ActiveAdmin.application.filter_attributes.map(&:to_s) }

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
      expect(secret_columns).to include('password_digest', 'reset_password_token', 'reset_password_sent_at',
                                        'keys_valid_since', 'encrypted_password')

      models_with_a_list.each do |model|
        leaked = model.ransackable_attributes & secret_columns
        expect(leaked).to be_empty, "#{model.name} lists #{leaked.inspect}"
      end
    end
  end

  # Ransack asks for this list when a filter or sort key is not one of the
  # model's own columns, and raises when a model has none. So every model
  # gets an empty list from ApplicationRecord, and names an association only
  # on purpose.
  describe '.ransackable_associations' do
    it 'is empty unless a model names its own' do
      expect(Resident.ransackable_associations).to eq([])
      expect(described_class.ransackable_associations).to eq([])
    end
  end
end
