# typed: false
# frozen_string_literal: true

# The jobs run on their own dyno: `worker: ... bin/jobs --mode async` in
# the Procfile. bin/jobs starts Solid Queue's supervisor, which runs a
# dispatcher, a worker and a scheduler as threads of its own process
# (config/queue.yml, config/recurring.yml).
#
# Each time the supervisor starts, enqueue every recurring job that missed
# its last tick while the dyno was down (RecurringCatchUp says why). The
# supervisor's start hook runs once, in the supervisor, after it boots and
# before it starts the other three. The worker, dispatcher and scheduler
# hooks would run once for each of them. RecurringCatchUp never raises, and Solid Queue rescues an
# error from a hook too, so the supervisor still starts its processes.
# spec/config/initializers/solid_queue_spec.rb pins this.
SolidQueue.on_start { RecurringCatchUp.call }
