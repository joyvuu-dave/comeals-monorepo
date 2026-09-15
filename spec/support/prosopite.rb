# frozen_string_literal: true

# prosopite fails a spec that runs an N+1 query: the same SQL shape, run
# again and again from the same Ruby line.
#
# Where it watches:
#   - every request, through Prosopite::Middleware::Rack
#     (config/environments/test.rb), so request and admin specs are
#     covered one request at a time;
#   - every example under spec/services and spec/serializers, where a
#     screen or a task is built from many rows.
# Model specs are not watched: a model spec touches one row at a time on
# purpose. Factories are never watched: a factory writes one row, and
# what a create_list repeats is setup, not the code under test. An
# example tagged `prosopite: false` is not watched either; say why next
# to the tag.
#
# Bullet stays in the development group. It shows a footer on a page but
# cannot fail a spec, and it misses repeats that go through a scope or a
# `first` on an association. goldiloader loads most associations in one
# query on its own, so what is left for prosopite is the repeat goldiloader
# cannot merge.
#
# To allow a repeat that is right, add its file (or a regexp on the stack
# line) to allow_stack_paths below with a comment that names the repeat
# and why it is fine. Prefer the fix: a preload, an includes, or one
# query for the set. A query is allowed when any line of its call stack
# matches, so a whole file hides every repeat under it too; name a method
# when one is enough.
require 'prosopite'

Prosopite.raise = true
Prosopite.rails_logger = true
Prosopite.allow_stack_paths = [
  # Every row write locks its meal first, one lock query per row. That is
  # the concern's whole point (ADR 0003); a second lock on a row this
  # transaction already holds costs Postgres nothing.
  'app/models/concerns/locks_its_meal_first.rb',
  # The audited gem reads the last version number before it writes each
  # audit row: one read per audited write.
  %r{/gems/audited-},
  # Rack::Attack keeps one counter row per throttle, and a request can
  # fall under two throttles (login by IP and API by IP). Two rows read
  # from the same line are two counters, not a repeat.
  %r{/gems/rack-attack-},
  # A moved meal has two days, and each day asks for its two neighbours
  # (the meal before and the meal after) so their pages can be refreshed.
  # Four lookups, once per move.
  /meal\.rb:\d+:in 'Meal#neighbour_ids'/,
  # The nightly check reads each settlement's rows on their own, on
  # purpose: one settlement's check must not depend on another's rows.
  # It runs once a night over every settlement, about twelve a year.
  'app/services/ledger_verification.rb',
  # Known N+1 on the meal page's history modal: each audit row looks up
  # the record it names, and its resident, by id (#84).
  'app/services/audit_description.rb'
]

# A factory create runs with the scan paused, and so does everything it
# does on the way (callbacks, validations, associated records).
module FactoryBot
  module Strategy
    class Create
      prepend(Module.new do
        def result(evaluation)
          Prosopite.pause { super }
        end
      end)
    end
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/(services|serializers)/}) do |metadata|
    metadata[:prosopite] = true unless metadata.key?(:prosopite)
  end

  config.around(:each, :prosopite) do |example|
    Prosopite.scan { example.run }
  end

  config.around(:each, prosopite: false) do |example|
    Prosopite.enabled = false
    example.run
  ensure
    Prosopite.enabled = true
  end
end
