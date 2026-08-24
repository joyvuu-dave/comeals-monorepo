# frozen_string_literal: true

namespace :rotations do
  desc 'Send new-rotation notification emails for rotations that have not yet been announced.'
  task notify_new: :environment do
    unless BROADCAST_EMAIL_ENABLED
      Rails.logger.info('rotations:notify_new skipped: broadcast email is off ' \
                        '(set BROADCAST_EMAIL_ENABLED=true to enable)')
      next
    end

    start_time = Time.current

    # Only announce rotations created in the last 7 days. This bounds the
    # task by construction: if broadcast email is off (or failing) for
    # months, turning it back on announces only what is new. The backlog
    # that piled up in the meantime is out of scope forever — no flood is
    # possible.
    Rotation.where(new_rotation_notified_at: nil)
            .where(created_at: 7.days.ago..)
            .find_each do |rotation|
      residents = rotation.community.residents.where(active: true).where.not(email: nil)
      result = PacedDelivery.deliver(residents, mailer: 'new_rotation_email') do |resident|
        ResidentMailer.new_rotation_email(resident, rotation, rotation.community)
      end

      if result.complete?
        rotation.update_column(:new_rotation_notified_at, Time.current)
        Rails.logger.info("Rotation #{rotation.id}: #{result.sent} new-rotation email(s) sent")
      else
        Rails.logger.error("Rotation #{rotation.id}: #{result.failed} email(s) failed, " \
                           "#{result.skipped} over the cap, #{result.sent} sent — not marking as notified")
      end
    end

    total_time = Time.current - start_time
    Rails.logger.info("rotations:notify_new completed in #{total_time.round(2)}s")
  end
end
