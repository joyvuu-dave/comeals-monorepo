# typed: false
# frozen_string_literal: true

# No statement timeout on the connection that db:create, db:drop and
# db:test:purge use for CREATE DATABASE and DROP DATABASE.
#
# Rails opens that connection to the "postgres" database with the app's own
# config, so it got the 10 s statement_timeout from config/database.yml.
# That limit is for the app's queries. CREATE DATABASE forces a checkpoint,
# which writes every changed page on the whole server to disk, so how long
# it takes depends on what every other database on the server is doing. On
# the shared local server, with other worktrees running their tests, it took
# more than 10 s: bin/agent-worktree failed at db:test:purge with
# PG::QueryCanceled, and a cancelled DROP DATABASE left the test database
# marked invalid, so nothing could connect to it until it was dropped by
# hand.
#
# Only statement_timeout changes. The isolation level and lock_timeout stay.
# createdb and dropdb, which bin/mutant and bin/agent-worktree-done use,
# never had a timeout.
#
# public_schema_config is a private Rails method;
# spec/config/database_tasks_statement_timeout_spec.rb fails if a Rails
# upgrade renames it.
module DatabaseTasksWithoutStatementTimeout
  private

  def public_schema_config
    config = super
    variables = config.fetch(:variables, {}).merge('statement_timeout' => '0')
    config.merge(variables: variables)
  end
end

ActiveRecord::Tasks::PostgreSQLDatabaseTasks.prepend(DatabaseTasksWithoutStatementTimeout)
