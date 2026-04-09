# frozen_string_literal: true

class AddDeleteTriggerToCommunities < ActiveRecord::Migration[8.1]
  def up
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function body needs preserved formatting
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_community_delete()
      RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION 'Cannot delete the singleton community record';
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER prevent_community_delete
      BEFORE DELETE ON communities
      FOR EACH ROW
      EXECUTE FUNCTION prevent_community_delete();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    execute 'DROP TRIGGER IF EXISTS prevent_community_delete ON communities'
    execute 'DROP FUNCTION IF EXISTS prevent_community_delete()'
  end
end
