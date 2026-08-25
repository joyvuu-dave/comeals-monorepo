# frozen_string_literal: true

module Api
  module V1
    class CommunitiesController < ApiController
      before_action :authenticate, except: [:ical]

      # GET /api/v1/communities/:id/ical
      def ical
        community = Community.instance
        feed = MealIcalFeed.new(community, calendar_name: community.name)

        community.meals.find_each do |meal|
          feed.add_meal(meal,
                        summary: 'Common Dinner',
                        description: "#{meal.description}\n\n\n\nSign up here: #{root_url}/meals/#{meal.id}/edit")
        end

        render plain: feed.to_ical, content_type: 'text/calendar'
      end

      # GET /api/v1/communities/:id/birthdays
      def birthdays
        month_int = if params[:start]
                      (Date.parse(params[:start]) + 2.weeks).month
                    else
                      Community.instance.today.month
                    end

        residents = Community.instance.residents.active.where('extract(month from birthday) = ?', month_int)
        render json: ResidentBirthdaySerializer.new(residents)
      end

      # GET /api/v1/communities/:id/hosts
      def hosts
        hosts = Resident.adult.active.joins(:unit).order('units.name').pluck(
          'residents.id', 'residents.name', 'units.name'
        )
        render json: hosts
      end

      # GET /api/v1/communities/:id/calendar/:date
      #
      # The :id in the path is not read. There is exactly one community
      # (see CLAUDE.md), so this always answers for Community.instance. The
      # path keeps the :id only so existing links and the SPA's cookie-based
      # URLs stay valid.
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

        result = cached_month(Community.instance,
                              month: month, year: year,
                              start_date: start_date, end_date: end_date,
                              month_int_array: month_int_array)

        # stale? digests `result` into an ETag. When the client sends a matching
        # If-None-Match, Rails auto-renders 304 Not Modified with an empty body.
        # Cache-Control defaults to private, no-cache, must-revalidate — browsers
        # revalidate on every request, so freshness semantics are identical to
        # the pre-ETag behavior. The win is bandwidth: a 304 is ~200 bytes vs.
        # a full calendar JSON payload.
        render json: result if stale?(etag: result, public: false)
      end

      private

      # The key is per month, and is what a write deletes (LiveUpdate).
      # The version is read from the rows before they are serialized, so
      # a write that lands mid-build cannot leave a stale copy that
      # serves anyone. See Community#calendar_cache_version.
      def cached_month(community, **serializer_params)
        key = community.calendar_cache_key(serializer_params[:year], serializer_params[:month])
        version = community.calendar_cache_version(serializer_params[:start_date], serializer_params[:end_date])
        Rails.cache.fetch(key, version: version, expires_in: 1.hour) do
          CalendarSerializer.new(community, params: serializer_params).to_h
        end
      end
    end
  end
end
