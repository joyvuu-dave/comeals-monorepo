# frozen_string_literal: true

# This file is used by Rack-based servers to start the application.

require_relative 'config/environment'
require_relative 'lib/schema_boot_check'

# Puma loads this file, and a one-off process (a console, a rake task,
# the release phase) does not, so only web refuses a database the code
# does not fit (lib/schema_boot_check.rb).
SchemaBootCheck.verify!('The web process')

run Rails.application
Rails.application.load_server
