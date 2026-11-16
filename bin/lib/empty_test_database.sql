-- Empties every table of a test database except Rails' own two, in one
-- TRUNCATE. bin/test-integration runs it after the integration suite.
-- Naming tables and letting CASCADE follow foreign keys missed every
-- table no foreign key reaches: request_keys kept a run's guest removal
-- keys, and the next run's removals were answered from them (#295).
-- Listing every table instead means a table added later is emptied too.
-- spec/bin/test_integration_cleanup_spec.rb runs this file.
DO $$
BEGIN
  EXECUTE (
    SELECT 'TRUNCATE ' || string_agg(format('%I', tablename), ', ') || ' CASCADE'
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
  );
END
$$;
