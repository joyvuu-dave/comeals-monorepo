# frozen_string_literal: true

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
