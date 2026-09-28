# typed: true
# frozen_string_literal: true

# The event edit form: GET /api/v1/events/:id. The fields public/api.md
# lists and no others, so a new column is not sent until someone adds it
# here (#103). The form reads all of them but the timestamps. Not
# EventSerializer: that one builds a calendar chip, whose id is a cache
# key and whose title has the hours in it.
class EventFormSerializer
  include Alba::Resource

  attributes :id,
             :title,
             :description,
             :start_date,
             :end_date,
             :allday,
             :created_at,
             :updated_at
end
