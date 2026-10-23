# typed: false
# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
# :token covers the API-key query-param fallback and the reset_token the
# reset page posts. Rails matches a part of a name, so reset_token is
# filtered too. This hides a value in the "Parameters:" line and in a
# query string, never in a path, so a secret must never travel in a path
# (Api::V1::ResidentsController).
Rails.application.config.filter_parameters += %i[password token]
