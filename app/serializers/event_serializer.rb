# typed: true
# frozen_string_literal: true

# == Schema Information
#
# Table name: events
#
#  id           :bigint           not null, primary key
#  allday       :boolean          default(FALSE), not null
#  description  :string           default(""), not null
#  end_date     :datetime
#  start_date   :datetime         not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_events_on_start_date  (start_date)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
class EventSerializer
  include Alba::Resource

  CHIP_COLOR = '#7ebc35'

  attributes :id,
             :type,
             :title,
             :description,
             :start,
             :end,
             :url,
             :allDay,
             :color

  def id(event)
    event.cache_key_with_version
  end

  def type(event)
    event.class.to_s
  end

  def title(event)
    if event.allday
      "ALL DAY\nEvent\n#{event.title}"
    else
      "#{event.start_date.strftime('%l:%M%P')} - #{event.end_date.strftime('%l:%M%P')}\nEvent\n#{event.title}"
    end
  end

  def description(event)
    "Event\n#{event.description}"
  end

  def start(event)
    event.allday ? event.start_date + 1.minute : event.start_date
  end

  def end(event)
    event.allday ? event.start_date + 1.minute : event.end_date
  end

  def url(event)
    "events/edit/#{event.id}"
  end

  def allDay(event) # rubocop:disable Naming/MethodName -- camelCase required by frontend API contract
    event.allday
  end

  def color(_event)
    CHIP_COLOR
  end
end
