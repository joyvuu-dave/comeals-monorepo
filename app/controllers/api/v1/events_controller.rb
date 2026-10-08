# typed: true
# frozen_string_literal: true

module Api
  module V1
    class EventsController < ApiController
      before_action :authenticate
      before_action :set_resource, only: %i[show update destroy]

      # GET /api/v1/events/:id
      def show
        render json: EventFormSerializer.new(@event)
      end

      # POST /api/v1/events
      #
      # The one create/update difference in parsing: what a missing
      # all_day param means. Create defaults it to false; update keeps
      # the event's stored value. An all_day that is sent must be a value
      # TrueOrFalse takes (#138). Before, only the text "true" was true,
      # so "1" made a timed event, and so did "True" and "yes".
      def create
        flags = TrueOrFalse.from_params(params, %i[all_day], required: false)
        return render_refused(flags) if flags.is_a?(String)

        allday = flags.fetch(:all_day, false)
        times = parse_start_end_params(allday: allday)
        return render_refused(times) if times.is_a?(String)

        event = Event.new(start_date: times[:start_date], end_date: times[:end_date], title: params[:title],
                          description: params[:description] || '', allday: allday)
        render_retrying_on_conflict do
          if event.save
            { json: { message: 'Event has been created' } }
          else
            { json: { message: event.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
      end

      # PATCH /api/v1/events/:id/update
      #
      # A field left out of the body keeps its stored value, the same rule
      # as all_day above. description is NOT NULL in the database and has
      # no presence validation, so passing a missing param through as nil
      # used to raise from the database and return a 500 (#69).
      def update
        flags = TrueOrFalse.from_params(params, %i[all_day], required: false)
        return render_refused(flags) if flags.is_a?(String)

        allday = flags.fetch(:all_day, @event.allday)
        times = parse_start_end_params(allday: allday)
        return render_refused(times) if times.is_a?(String)

        description = params.key?(:description) ? params[:description] : @event.description
        title = params.key?(:title) ? params[:title] : @event.title

        render_retrying_on_conflict do
          if @event.update(start_date: times[:start_date], end_date: times[:end_date], allday: allday,
                           description: description, title: title)
            { json: { message: 'Event has been updated' } }
          else
            { json: { message: @event.errors.full_messages.join("\n") }, status: :bad_request }
          end
        end
      end

      # DELETE /api/v1/events/:id/delete
      def destroy
        render_retrying_on_conflict do
          @event.destroy!
          { json: { message: 'Event has been removed' } }
        end
      end

      private

      def set_resource
        @event = Event.find_by(id: params[:id])

        not_found_api if @event.blank?
      end
    end
  end
end
