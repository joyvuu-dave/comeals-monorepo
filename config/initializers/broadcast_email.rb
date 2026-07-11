# frozen_string_literal: true

# Kill switch for broadcast email — the rake tasks that mail many residents
# at once (rotations:notify_new, residents:notify). Default is OFF: a fresh
# environment can never accidentally email the whole community.
#
# Broadcasts were turned off in July 2026 after the per-message SMTP login
# pattern tripped Gmail's throttle and no broadcast had delivered since 2023.
# Before turning this back on, build a paced sender: one SMTP session per
# run, a pause between messages, a per-run cap.
#
# To enable: heroku config:set BROADCAST_EMAIL_ENABLED=true
# (and re-add the two jobs to Heroku Scheduler).
#
# Transactional mail (password resets) and the manual reconciliation mailers
# do not check this switch — they are one-at-a-time and user-triggered.
BROADCAST_EMAIL_ENABLED = ENV['BROADCAST_EMAIL_ENABLED'] == 'true'
