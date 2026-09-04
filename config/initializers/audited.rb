# typed: false
# frozen_string_literal: true

Audited.config do |config|
  # One global method name, resolved per controller: API requests attribute
  # audits to the resident, ActiveAdmin requests to the admin user. Defined
  # on ApiController and ApplicationController respectively.
  config.current_user_method = :audited_user

  # Never audit `touch`. Every child write (a signup, a guest, a bill)
  # touches its meal, and audited 5.8 audits touches by default. The
  # touch audit diffs the record's `previous_changes` against the last
  # stored audit — and on an instance that was created in the same
  # process, previous_changes still holds the creation diff, whose Time
  # values serialize differently than the stored audit's strings. The
  # phantom rows that survive that comparison ("start_time [nil, ...]")
  # showed in the meal history modal as "Meal, update" and even "Menu
  # description updated" (#56). A touch never carries information here:
  # the child's own audit, associated with the meal, is the real record.
  config.ignored_default_callbacks = [:touch]
end
