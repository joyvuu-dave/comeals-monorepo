# frozen_string_literal: true

class AddUniqueIndexToResidentBalances < ActiveRecord::Migration[8.1]
  def up
    # Log and remove duplicates before adding unique index. Keep the most recently
    # updated record for each resident_id (the freshest balance). We keep the
    # freshest (not earliest) because balances are recomputed daily — the most
    # recent write has the most accurate data.
    dupes = execute(<<~SQL.squish).to_a
      SELECT id, resident_id, amount, updated_at
      FROM resident_balances
      WHERE id NOT IN (
        SELECT DISTINCT ON (resident_id) id
        FROM resident_balances
        ORDER BY resident_id, updated_at DESC
      )
    SQL

    if dupes.any?
      say "Deleting #{dupes.size} duplicate resident_balances:"
      dupes.each do |row|
        say "  id=#{row['id']} resident_id=#{row['resident_id']} " \
            "amount=#{row['amount']} updated_at=#{row['updated_at']}"
      end

      execute <<~SQL.squish
        DELETE FROM resident_balances
        WHERE id IN (#{dupes.pluck('id').join(', ')})
      SQL
    end

    remove_index :resident_balances, :resident_id
    add_index :resident_balances, :resident_id, unique: true
  end

  def down
    remove_index :resident_balances, :resident_id, unique: true
    add_index :resident_balances, :resident_id
  end
end
