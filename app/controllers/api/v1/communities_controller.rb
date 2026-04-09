# frozen_string_literal: true

module Api
  module V1
    class CommunitiesController < ApiController
      before_action :authenticate, except: [:ical]

      # GET /api/v1/communities/:id/ical
      def ical
        community = Community.instance

        require 'icalendar/tzinfo'
        tzid = community.timezone
        tz = TZInfo::Timezone.get tzid
        timezone = tz.ical_timezone DateTime.new 2017, 6, 1, 8, 0, 0

        cal = Icalendar::Calendar.new
        cal.add_timezone timezone

        cal.x_wr_calname = community.name

        community.meals.find_each do |meal|
          event = Icalendar::Event.new

          meal_date = meal.date
          meal_date_time_start = DateTime.new(meal_date.year, meal_date.month, meal_date.day,
                                              meal_date.sunday? ? 18 : 19, 0)
          meal_date_time_end = DateTime.new(meal_date.year, meal_date.month, meal_date.day,
                                            meal_date.sunday? ? 20 : 21, 0)

          event.dtstart = Icalendar::Values::DateTime.new meal_date_time_start, 'tzid' => tzid
          event.dtend = Icalendar::Values::DateTime.new meal_date_time_end, 'tzid' => tzid
          event.summary = 'Common Dinner'
          event.description = "#{meal.description}\n\n\n\nSign up here: #{root_url}/meals/#{meal.id}/edit"
          cal.add_event(event)
        end

        render plain: cal.to_ical, content_type: 'text/calendar'
      end

      # GET /api/v1/communities/:id/birthdays
      def birthdays
        month_int = if params[:start]
                      (Date.parse(params[:start]) + 2.weeks).month
                    else
                      Time.zone.today.month
                    end

        render json: Community.instance.residents.active.where('extract(month from birthday) = ?', month_int),
               each_serializer: ResidentBirthdaySerializer
      end

      # GET /api/v1/communities/:id/hosts
      def hosts
        hosts = Resident.adult.active.joins(:unit).order('units.name').pluck(
          'residents.id', 'residents.name', 'units.name'
        )
        render json: hosts, adapter: nil
      end

      # GET /api/v1/communities/:id/calendar/:date
      def calendar
        begin
          date = Date.parse(params[:date])
        rescue ArgumentError, TypeError
          return render json: { message: 'Invalid date' }, status: :bad_request
        end

        start_date = date.beginning_of_month.beginning_of_week(:sunday)
        end_date = start_date + 41.days
        month_int_array = (start_date..end_date).map(&:month).uniq

        month = (start_date + 20.days).month
        year = (start_date + 20.days).year

        start_date = start_date.to_s
        end_date = end_date.to_s

        community = Community.instance
        key = community.calendar_cache_key(year, month)

        result = Rails.cache.fetch(key, expires_in: 1.hour) do
          ActiveModelSerializers::SerializableResource.new(
            community,
            month: month, year: year,
            start_date: start_date, end_date: end_date,
            month_int_array: month_int_array,
            serializer: CalendarSerializer
          ).as_json
        end

        render json: result
      end

      private

      def authenticate
        not_authenticated_api unless signed_in_resident_api?
      end
    end
  end
end
