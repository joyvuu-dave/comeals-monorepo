# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261009130100_validate_guests_multiplier_check.rb')

# The migration that checks every guest already in the table against
# the Adult-or-Child rule refuses to run while a guest has another price,
# and names each one with its meal's date. Without the guard the release
# would fail with a message about a constraint, and the person deploying
# would have to find the guests by hand.
RSpec.describe ValidateGuestsMultiplierCheck do
  let(:community) { create(:community) }
  let(:connection) { ActiveRecord::Base.connection }

  # suppress_messages keeps the migration's "-- select_rows ..." lines
  # out of the RSpec output.
  def refuse_guests_with_another_price!
    migration = described_class.new
    migration.suppress_messages { migration.send(:refuse_guests_with_another_price) }
  end

  it 'passes when every guest is an adult or a child' do
    create(:guest, meal: create(:meal, community: community), multiplier: Multiplier::FULL)
    create(:guest, meal: create(:meal, community: community), multiplier: Multiplier::HALF)

    expect { refuse_guests_with_another_price! }.not_to raise_error
  end

  it 'refuses, naming each guest, its meal date and its price, when guests have another price' do
    create(:guest, meal: create(:meal, community: community, date: Date.new(2026, 5, 1)))
    free = create(:guest, meal: create(:meal, community: community, date: Date.new(2026, 5, 9)))
    odd = create(:guest, meal: create(:meal, community: community, date: Date.new(2026, 4, 2)))
    # The CHECK forbids these rows, so drop it for this example (rolled
    # back with the transaction) and write them the way raw SQL would.
    connection.remove_check_constraint(:guests, name: 'guests_multiplier_adult_or_child')
    free.update_columns(multiplier: Multiplier::FREE)
    odd.update_columns(multiplier: 3)

    expect { refuse_guests_with_another_price! }.to raise_error(
      RuntimeError,
      "2 guest(s) have a price that is not 2 (Adult) or 1 (Child): guest #{odd.id} on 2026-04-02 (3), " \
      "guest #{free.id} on 2026-05-09 (0). Give each one 2 or 1, then run this migration again."
    )
  end
end
