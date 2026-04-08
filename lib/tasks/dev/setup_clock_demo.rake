# frozen_string_literal: true

namespace :dev do
  desc 'Prepare local database so every scheduled task does visible work on next clock run.'
  task setup_clock_demo: :environment do
    abort 'dev:setup_clock_demo is only for development!' unless Rails.env.development?

    community = Community.first!
    puts ''

    # 1. Clear resident balances → billing:recalculate rebuilds them from source data.
    puts '1. Clearing resident balances...'
    count = ResidentBalance.delete_all
    puts "   Deleted #{count} balances. billing:recalculate will rebuild them."

    # 2. Set one adult's multiplier to child → set_multiplier corrects it back to 2.
    puts ''
    puts '2. Setting one adult multiplier to child (1)...'
    adult = community.residents.where(active: true).where('multiplier >= 2').order(:id).first!
    adult.update_columns(multiplier: 1)
    puts "   #{adult.name} (id=#{adult.id}) multiplier set to 1. set_multiplier will fix it."

    # 3. Mark ALL existing rotations as announced so rotations:notify_new doesn't
    #    email about years of historical rotations. The new rotation created by
    #    create_rotations (step 4) will have new_rotation_notified_at=nil, so
    #    notify_new will announce just that one.
    puts ''
    puts '3. Marking all existing rotations as already announced...'
    updated = Rotation.where(new_rotation_notified_at: nil)
                      .update_all(new_rotation_notified_at: Time.current)
    puts "   Marked #{updated} rotations. Only the newly created rotation will trigger notify_new."

    # 4. Delete the most recent rotation and its meals so that meals no longer extend
    #    6 months into the future. create_rotations will detect this and create a new one.
    #    Meals must be destroyed explicitly because dependent: :nullify would orphan them,
    #    and orphaned meals block create_rotations.
    puts ''
    puts '4. Deleting most recent rotation to trigger create_rotations...'
    last_rotation = community.rotations.where.not(start_date: nil).order(start_date: :desc).first!
    meal_count = last_rotation.meals.count
    last_rotation.meals.destroy_all
    last_rotation.destroy!
    puts "   Deleted rotation #{last_rotation.id} (start=#{last_rotation.start_date}, #{meal_count} meals)."
    puts '   create_rotations will recreate it. notify_new will announce it.'

    # Clean up any rotations with nil start_date (garbage records with no meals).
    community.rotations.where(start_date: nil).find_each do |r|
      r.meals.destroy_all
      r.destroy!
      puts "   Cleaned up empty rotation #{r.id} (nil start_date)."
    end

    # 5. Verify residents:notify has an upcoming rotation to work with.
    puts ''
    puts '5. Checking residents:notify prerequisites...'
    upcoming = Rotation.where('start_date > ?', Time.zone.today)
                       .where(start_date: ...(Time.zone.today + 1.week))
                       .where(residents_notified: false)
    if upcoming.any?
      upcoming.each do |r|
        open_count = r.meals.left_joins(:bills).group(:id).having('COUNT(bills.id) < 2').count.size
        puts "   Rotation #{r.id} (start=#{r.start_date}): #{open_count} meals need cooks."
      end
    else
      puts '   No rotation starting within 7 days. residents:notify will be a no-op.'
    end

    puts ''
    puts '--- Setup complete! ---'
    puts ''
    puts 'Start the dev server:'
    puts '  bin/dev'
    puts ''
    puts 'Watch the clock output for task execution, then check emails at:'
    puts '  http://localhost:3000/letter_opener'
    puts ''
  end
end
