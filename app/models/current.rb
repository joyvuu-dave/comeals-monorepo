# frozen_string_literal: true

# Per-request attributes. Automatically reset between requests by Rails middleware.
# See https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html
class Current < ActiveSupport::CurrentAttributes
  attribute :community
end
