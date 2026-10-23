# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261023130100_clear_reset_tokens_stored_as_mailed.rb')

# The data migration that empties the old reset token column. Before it,
# a live token sat in residents.reset_password_token exactly as it was
# mailed. Resident ignores that column now, so the rows are written with
# SQL here.
RSpec.describe ClearResetTokensStoredAsMailed do
  let(:migration) { described_class.new }
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:connection) { ActiveRecord::Base.connection }

  def migrate(direction)
    out = StringIO.new
    $stdout = out
    migration.migrate(direction)
    out.string
  ensure
    $stdout = STDOUT
  end

  def old_columns(resident)
    connection.select_rows(<<~SQL.squish).first
      SELECT reset_password_token, reset_password_sent_at FROM residents WHERE id = #{Integer(resident.id)}
    SQL
  end

  def store_plain_token(resident, token)
    connection.execute(<<~SQL.squish)
      UPDATE residents SET reset_password_token = #{connection.quote(token)}, reset_password_sent_at = now()
      WHERE id = #{Integer(resident.id)}
    SQL
  end

  it 'empties the plain token and its time on every row that has one, and says how many' do
    ann = create(:resident, community: community, unit: unit)
    bob = create(:resident, community: community, unit: unit)
    store_plain_token(ann, 'ann-plain-token')
    store_plain_token(bob, 'bob-plain-token')

    output = migrate(:up)

    expect([old_columns(ann), old_columns(bob)]).to eq([[nil, nil], [nil, nil]])
    expect(output).to include('Cleared 2 reset token(s)')
  end

  # A token stored the old way is nobody's link any more, before the
  # migration runs too: the code looks up only the digest.
  it 'leaves a token that was stored the old way unusable' do
    ann = create(:resident, community: community, unit: unit)
    store_plain_token(ann, 'ann-plain-token')

    expect(PasswordReset.resident_for('ann-plain-token')).to be_nil
  end

  it 'leaves a reset made the new way alone' do
    ann = create(:resident, community: community, unit: unit)
    token = give_reset_token(ann)

    migrate(:up)

    expect(PasswordReset.resident_for(token)).to eq(ann)
  end

  it 'does nothing on the way down' do
    expect { migrate(:down) }.not_to raise_error
  end

  it_behaves_like 'a data migration that tries a conflict again', described_class
end
