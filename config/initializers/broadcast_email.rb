# frozen_string_literal: true

# Kill switch for broadcast email — the rake tasks that mail many residents
# at once (rotations:notify_new, residents:notify). Default is OFF: a fresh
# environment can never accidentally email the whole community.
#
# Broadcasts were turned off in July 2026 after the per-message SMTP login
# pattern tripped Gmail's throttle and no broadcast had delivered since 2023.
# The paced sender that was the condition for turning them back on exists
# now: PacedDelivery (one SMTP session per run, a pause between messages, a
# per-run cap), and every path that mails more than one person uses it.
#
# To enable: heroku config:set BROADCAST_EMAIL_ENABLED=true
# (and re-add the two jobs to Heroku Scheduler).
#
# Transactional mail (password resets) and the settlement mail to cooks do
# not check this switch — a person triggers them, for one period at a time.
# They still go through PacedDelivery when there is more than one message.
BROADCAST_EMAIL_ENABLED = ENV['BROADCAST_EMAIL_ENABLED'] == 'true'
