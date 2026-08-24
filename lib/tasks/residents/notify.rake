# frozen_string_literal: true

namespace :residents do
  desc 'Notify residents they need to sign up for a meal.'
  task notify: :environment do
    unless BROADCAST_EMAIL_ENABLED
      Rails.logger.info('residents:notify skipped: broadcast email is off ' \
                        '(set BROADCAST_EMAIL_ENABLED=true to enable)')
      next
    end

    start_time = Time.current

    # Find all the rotations that start within the next week where we haven't already notified the residents
    Rotation.where('start_date > ?', Time.zone.today)
            .where(start_date: ...(Time.zone.today + 1.week))
            .where(residents_notified: false)
            .find_each do |rotation|
      Rails.logger.info("Processing rotation #{rotation.id}: #{rotation.description}...")

      # For the given rotation, find the residents who aren't already signed up to cook
      meal_ids = rotation.meal_ids
      bill_ids = Bill.where(meal_id: meal_ids)

      # Signed Up Residents
      signed_up_residents_ids = Bill.joins(:resident).where(id: bill_ids).pluck('residents.id')

      eligible_cooks = Resident.eligible_cooks.where.not(email: nil).joins(:unit).order('units.name')

      # Meals with less than 2 cooks
      open_meal_dates = Meal.order(:date)
                            .where(rotation_id: rotation.id)
                            .left_joins(:bills)
                            .group(:id)
                            .having('COUNT(bills.id) < ?', 2)
                            .pluck(:date)

      to_notify = eligible_cooks.reject { |resident| signed_up_residents_ids.include?(resident.id) }
      result = PacedDelivery.deliver(to_notify, mailer: 'rotation_signup_email') do |resident|
        ResidentMailer.rotation_signup_email(resident, rotation, open_meal_dates, rotation.community)
      end

      if result.complete?
        rotation.update(residents_notified: true)
      else
        Rails.logger.error("Rotation #{rotation.id}: #{result.failed} email(s) failed, " \
                           "#{result.skipped} over the cap, #{result.sent} sent — not marking as notified")
      end
    end

    total_time = Time.current - start_time
    Rails.logger.info("Resident Notification Complete in #{total_time}s.")
  end
end
