# frozen_string_literal: true

require 'yaml'

module DeployWatch
  # The recurring jobs in config/recurring.yml, for one question: which job
  # was due in this stretch of time? It reads only the forms that file uses:
  # "M H * * * UTC" and "M * * * * UTC". Any other form is listed in
  # #unread, and the Jobs check says it could not read that job.
  class Schedule
    FORM = /\A(\d+) (\d+|\*) \* \* \* UTC\z/
    HOUR = 3600

    attr_reader :unread

    def self.from_file(path)
      new(YAML.safe_load_file(path, aliases: true).fetch('production').transform_values { |task| task['schedule'] })
    end

    def initialize(schedules)
      forms = schedules.transform_values { |schedule| FORM.match(schedule.to_s) }
      @unread = forms.select { |_key, form| form.nil? }.keys
      @tasks = forms.compact.transform_values { |form| [form[1].to_i, form[2]] }
    end

    # Every [key, time] due from first to last, both included, earliest first.
    def due(first, last)
      hours(first, last).flat_map { |hour| due_in(hour) }
                        .select { |_key, time| time.between?(first, last) }
                        .sort_by(&:last)
    end

    # The next [key, time] after this time, within two days.
    def next_after(time)
      due(time + 1, time + (48 * HOUR)).first
    end

    private

    def hours(first, last)
      start = first.to_i / HOUR * HOUR
      (start..last.to_i).step(HOUR).map { |seconds| Time.at(seconds).utc }
    end

    def due_in(hour)
      @tasks.filter_map do |key, (minute, hours)|
        [key, hour + (minute * 60)] if hours == '*' || hours.to_i == hour.hour
      end
    end
  end
end
