# frozen_string_literal: true

require 'rails_helper'

# The Common House screen signs in on the resident form with
# CommonHouseLogin::EMAIL, an address ending in .invalid (RFC 2606: no
# real address can). If a resident had that address too, a sign-in could
# not tell the two apart, so no resident may have any .invalid address:
# the model says why, and the CHECK holds for writes that skip it.
RSpec.describe Resident do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  it 'refuses the Common House address' do
    resident = build(:resident, community: community, unit: unit, email: CommonHouseLogin::EMAIL)

    expect(resident).not_to be_valid
    expect(resident.errors[:email]).to include('cannot end in .invalid. That address is for the Common House screen.')
  end

  it 'refuses any .invalid address, in any case' do
    resident = build(:resident, community: community, unit: unit, email: 'Someone@Example.INVALID')

    expect(resident).not_to be_valid
  end

  it 'takes an address that only has "invalid" in it' do
    resident = build(:resident, community: community, unit: unit, email: 'invalid@example.com')

    expect(resident).to be_valid
  end

  it 'refuses a .invalid address written past the model' do
    resident = create(:resident, community: community, unit: unit)

    expect { resident.update_column(:email, 'X@Comeals.Invalid') }
      .to raise_error(ActiveRecord::CheckViolation, /residents_email_not_invalid_domain/)
  end
end
