# frozen_string_literal: true

ActiveAdmin.register Community do
  # MENU
  menu label: 'Community'

  # STRONG PARAMS
  permit_params :name, :cap, :timezone, :meals_per_rotation,
                schedule: {}

  # CONFIG
  config.filters = false

  # ACTIONS
  # `new` and `create` stay routed so the very first Community can be created
  # through the UI on a fresh deployment. Once that row exists, SuperuserAdapter
  # refuses both — the "New Community" button is gone and the URLs are denied.
  actions :all, except: %i[destroy]

  controller do
    # For show/edit/update, coerce any ID param back to the singleton record.
    # Skipped for new/create (find_resource isn't called for those actions).
    def find_resource
      Community.instance
    end
  end

  # The live preview under the schedule grid. The form's JS posts the draft
  # grid here on every change; the reply is an HTML fragment of the dates the
  # draft would produce. Server-side so the holiday rules and date formatting
  # stay in one place. A collection route (no id) so the bootstrap
  # new-community form can preview too.
  collection_action :schedule_preview, method: :post do
    # Hand-written action: ActiveAdmin authorizes inside resource and
    # build_resource, neither of which runs here, so without this line the
    # adapter is never consulted (the meal_resident.rb trap, ADR 0004).
    authorize! :update, Community

    draft = Community.first || Community.new
    draft.assign_attributes(params.require(:community)
                                  .permit(:meals_per_rotation, schedule: {}))
    draft.validate
    schedule_errors = draft.errors.filter_map do |error|
      # Only the schedule fields decide the preview. A bootstrap draft has no
      # name yet; that is the form's problem at save time, not the preview's.
      error.full_message if %i[schedule meals_per_rotation].include?(error.attribute)
    end

    if schedule_errors.any?
      items = schedule_errors.map { |message| helpers.tag.li(message) }
      render html: helpers.tag.ul(helpers.safe_join(items), class: 'schedule-preview-errors'),
             status: :unprocessable_entity
    else
      shown = [draft.meals_per_rotation, 20].min
      dates = draft.meal_schedule.upcoming_dates(from: Time.zone.today, count: shown)
      items = dates.map { |date| helpers.tag.li(date.strftime('%a %b %-d, %Y')) }
      note = if shown < draft.meals_per_rotation
               helpers.tag.p("First #{shown} of #{draft.meals_per_rotation} meals in a rotation.",
                             class: 'schedule-preview-note')
             end
      render html: helpers.safe_join(
        [helpers.tag.p('Upcoming meals under this schedule:'),
         helpers.tag.ul(helpers.safe_join(items), class: 'schedule-preview-dates'),
         note].compact
      )
    end
  end

  # INDEX
  index do
    column :name
    column :cap do |community|
      number_to_currency(community.cap) if community.capped?
    end
    column :timezone

    actions
  end

  # SHOW
  show do
    attributes_table do
      row :id
      row :name
      row :cap do |community|
        number_to_currency(community.cap) if community.capped?
      end
      row :timezone
    end

    panel 'Meal schedule' do
      # Hand-built with attributes_table markup, not attributes_table_for:
      # its row() titleizes every label through human_attribute_name, which
      # turns "Week of Aug 2 (this week)" into "Week Of Aug 2 (This Week)".
      div class: 'attributes_table' do
        table do
          helpers.schedule_week_rows(community.schedule.length).each do |week_row|
            week = community.schedule[week_row[:slot]]
            tr do
              th week_row[:label]
              td week.empty? ? 'No meals' : week.map { |wday| Date::DAYNAMES[wday] }.join(', ')
            end
          end
          tr do
            th 'Meals per rotation'
            td community.meals_per_rotation
          end
        end
      end
      para helpers.schedule_repeat_note(community.schedule.length)

      last_meal_date = community.meals.maximum(:date)
      if last_meal_date
        para "Meals already exist through #{last_meal_date.strftime('%b %-d, %Y')}. This " \
             'schedule shapes meals created after that date. To apply a schedule change ' \
             'sooner, delete upcoming rotations (newest first) on the Rotations page — ' \
             'the nightly task recreates them under the current schedule within a day.'
      else
        para 'No meals exist yet. The nightly task will create them under this schedule.'
      end
    end
  end

  # FORM
  form do |f|
    f.inputs do
      f.input :name
      # The column is DECIMAL(12,8), so the raw value renders as "4.5" —
      # render it as money instead (MoneyFieldHelper, shared with Bill's
      # form).
      f.input :cap,
              label: 'Cap ($)',
              input_html: { value: helpers.money_field_value(f.object.cap) },
              hint: 'Most a meal can cost per multiplier unit, in whole cents. ' \
                    'Leave blank for no cap. The lowest cap you can set is $0.01.'
      f.input :timezone,
              as: :select,
              collection: Community::SUPPORTED_TIMEZONES.map { |name, iana| [name, iana] }
    end

    f.inputs 'Meal schedule' do
      # The grid: one row per week of the repeating cycle, one checkbox per
      # day. Rows appear in calendar order (this week first), and each row is
      # labeled with the real calendar week it maps to
      # (ScheduleWeekLabelHelper) — never "Week 1", which every reader takes
      # to mean "starting now". Checkbox names are community[schedule][SLOT][]
      # — the slot is the row's index in the stored schedule, which can
      # differ from its place on screen. The hidden "" input per row keeps a
      # fully-unchecked week in the params (the same trick Rails uses for
      # single checkboxes, applied per row). Behavior (add/remove week,
      # renaming, relabeling, live preview) lives in active_admin.js, fed
      # by the data attributes on the table.
      li class: 'schedule-grid-wrapper' do
        week_rows = helpers.schedule_week_rows(f.object.schedule.length)
        table({ id: 'schedule-grid' }.merge(helpers.schedule_grid_data)) do
          thead do
            tr do
              th ''
              Date::ABBR_DAYNAMES.each { |name| th name }
            end
          end
          tbody do
            week_rows.each do |week_row|
              # `input` here is Formtastic's method, not the HTML tag, so the
              # tags are hand-built strings. Every interpolated value is a
              # generated integer or day name, never user input. No ids: the
              # slot in the name is the only identity these need, and cloned
              # rows must not duplicate ids.
              week = f.object.schedule[week_row[:slot]]
              label = week_row[:label]
              field_name = "community[schedule][#{week_row[:slot]}][]"
              tr do
                td class: 'schedule-week-label' do
                  marker = %(<input type="hidden" name="#{field_name}" value="">)
                  text_node marker.html_safe # rubocop:disable Rails/OutputSafety -- built from a generated index, no user input
                  text_node label
                end
                (0..6).each do |wday|
                  td do
                    checked = week.include?(wday) ? ' checked="checked"' : ''
                    checkbox = %(<input type="checkbox" name="#{field_name}" value="#{wday}" ) +
                               %(aria-label="#{label} #{Date::DAYNAMES[wday]}"#{checked}>)
                    text_node checkbox.html_safe # rubocop:disable Rails/OutputSafety -- built from generated dates and DAYNAMES, no user input
                  end
                end
              end
            end
          end
        end
        button 'Add a week', type: 'button', id: 'schedule-add-week'
        button 'Remove last week', type: 'button', id: 'schedule-remove-week'
        para helpers.schedule_repeat_note(f.object.schedule.length),
             id: 'schedule-repeat-note'
      end

      f.input :meals_per_rotation,
              hint: 'How many meals each rotation contains (1 to 100).'

      li do
        div id: 'schedule-preview'
        # Which calendar week gets which row is fixed arithmetic
        # (MealSchedule::EPOCH), so the preview is how an admin sees the
        # phase, and rearranging days across rows is how they change it.
        para 'The preview shows the dates this schedule produces. If a day ' \
             'shows up in the wrong week, move it to the other week row.',
             class: 'schedule-preview-hint'
      end
    end

    f.actions
    f.semantic_errors
  end
end
