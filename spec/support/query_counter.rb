# frozen_string_literal: true

# Counts SQL queries executed during a block, excluding schema and cached
# queries. Shared so every query-count pin in the suite counts the same way.
#
# Usage in request specs (auto-included via rails_helper):
#   query_count = count_queries { get "/api/v1/..." }
#   expect(query_count).to be <= 15
#
# Available in every spec (included from rails_helper).
module QueryCounter
  def count_queries(&)
    count = 0
    counter = lambda { |*, payload|
      count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached]
    }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end
end
