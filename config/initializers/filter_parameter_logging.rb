# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
# :token covers both the API-key query-param fallback and the reset_password
# path param — both are secrets that must not land in request logs.
Rails.application.config.filter_parameters += %i[password token]
