# frozen_string_literal: true

require 'rails_helper'

# A guest pays as an adult (2) or as a child (1). The Guest model refuses
# any other price with a sentence (spec/models/guest_spec.rb, "the
# price"); this CHECK makes PostgreSQL refuse it from every write that
# skips the model (update_columns, update_all, a rake task, psql). Before
# it, the column took any number of 0 or more, and the admin meal form,
# which offers only Adult and Child, would quietly turn any other value
# into Adult on the next save.
RSpec.describe 'guests multiplier check constraint' do
  let(:community) { create(:community) }
  let!(:guest) { create(:guest, meal: create(:meal, community: community)) }

  it 'refuses a validation-skipping free guest' do
    expect do
      guest.update_columns(multiplier: Multiplier::FREE)
    end.to raise_error(ActiveRecord::StatementInvalid, /guests_multiplier_adult_or_child/)
  end

  # Each write runs in its own savepoint: a refused statement ends the
  # transaction it runs in, and the example's transaction must go on.
  it 'takes the two guest prices and refuses every other value' do
    accepted = (-1..4).select do |multiplier|
      Guest.transaction(requires_new: true) { guest.update_columns(multiplier: multiplier) }
    rescue ActiveRecord::CheckViolation
      false
    end

    expect(accepted).to eq(Multiplier::GUEST_PRICES.sort)
  end
end
