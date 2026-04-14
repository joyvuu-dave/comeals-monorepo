# frozen_string_literal: true

namespace :rotations do
  desc 'Send new-rotation notification emails for rotations that have not yet been announced.'
  task notify_new: :environment do
    start_time = Time.current

    Rotation.where(new_rotation_notified_at: nil).find_each do |rotation|
      residents = rotation.community.residents.where(active: true).where.not(email: nil)
      failures = 0
      sent = 0

      residents.each do |resident|
        ResidentMailer.new_rotation_email(resident, rotation, rotation.community).deliver_now
        sent += 1
      rescue *MAIL_DELIVERY_ERRORS => e
        failures += 1
        Rails.logger.error("new_rotation_email failed for #{resident.email}: #{e.class} - #{e.message}")
      end

      if failures.positive?
        Rails.logger.error("Rotation #{rotation.id}: #{failures} email(s) failed, " \
                           "#{sent} sent — not marking as notified")
      else
        rotation.update_column(:new_rotation_notified_at, Time.current)
        Rails.logger.info("Rotation #{rotation.id}: #{sent} new-rotation email(s) sent")
      end
    end

    total_time = Time.current - start_time
    Rails.logger.info("rotations:notify_new completed in #{total_time.round(2)}s")
  end
end
