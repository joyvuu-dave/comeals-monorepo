# typed: false
# frozen_string_literal: true

# See lib/database_pool_check.rb for the rule and the reasoning.
require_relative '../../lib/database_pool_check'

Rails.application.config.after_initialize do
  DatabasePoolCheck.verify!
end
