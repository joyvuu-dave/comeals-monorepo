# frozen_string_literal: true

require 'rails_helper'

# The 1900-01-01 placeholder ("adult, no birthday") is retired: a resident
# with no birthday leaves the column NULL. The model validation catches
# form input; this CHECK catches every write path that skips the model
# (update_all, update_columns, rake tasks, psql).
RSpec.describe 'residents birthday sentinel check constraint' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  it 'refuses a validation-skipping write of the old placeholder' do
    resident = create(:resident, community: community, unit: unit)

    expect do
      resident.update_columns(birthday: Date.new(1900, 1, 1))
    end.to raise_error(ActiveRecord::StatementInvalid, /residents_birthday_not_sentinel/)
  end

  it 'allows NULL and real birthdays' do
    expect do
      create(:resident, community: community, unit: unit, birthday: nil)
      create(:resident, community: community, unit: unit, birthday: Date.new(1990, 6, 15))
    end.not_to raise_error
  end
end
