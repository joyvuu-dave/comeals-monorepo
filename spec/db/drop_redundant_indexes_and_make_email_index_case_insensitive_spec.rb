# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260823120000_drop_redundant_indexes_and_make_email_index_case_insensitive.rb')

# The migration that makes residents.email unique without regard to case
# refuses to run while two rows differ only by case, and names them. Without
# the guard the index build would fail with the app scaled to zero.
RSpec.describe DropRedundantIndexesAndMakeEmailIndexCaseInsensitive do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:connection) { ActiveRecord::Base.connection }

  def refuse_duplicates!
    described_class.new.send(:refuse_case_only_duplicates)
  end

  it 'passes when every email is unique without regard to case' do
    create(:resident, community: community, unit: unit, email: 'ann@example.com')
    create(:resident, community: community, unit: unit, email: 'bob@example.com')

    expect { refuse_duplicates! }.not_to raise_error
  end

  it 'refuses, naming the rows, when two emails differ only by case' do
    ann = create(:resident, community: community, unit: unit, email: 'ann@example.com')
    bob = create(:resident, community: community, unit: unit, email: 'bob@example.com')
    # The new index forbids this pair, so drop it for this example (rolled
    # back with the transaction) and write the row the way raw SQL would.
    connection.remove_index(:residents, name: :index_residents_on_lower_email)
    connection.execute("UPDATE residents SET email = 'Ann@Example.com' WHERE id = #{bob.id}")

    # The migration lists each group ORDER BY email, which follows the
    # database's collation: en_US puts 'ann' first, a C collation puts
    # 'Ann' first. So the check takes the group in either order.
    lead = 'residents has emails that differ only by case: '
    tail = '. Merge or change them, then run this migration again.'
    expect { refuse_duplicates! }.to raise_error(RuntimeError) { |error|
      expect(error.message).to start_with(lead)
      expect(error.message).to end_with(tail)
      listed = error.message.delete_prefix(lead).delete_suffix(tail)
      expect(listed.split(', ')).to contain_exactly('ann@example.com', 'Ann@Example.com')
    }
    expect(ann.reload.email).to eq('ann@example.com')
  end
end
