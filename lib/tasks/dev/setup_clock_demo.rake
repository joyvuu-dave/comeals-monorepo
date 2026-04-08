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

    # 4. Delete the most recent rotation that has NO billed meals, so create_rotations
    #    has work to do. We must not destroy rotations with billed meals — that would
    #    cascade-delete financial data (Meal has_many :bills, dependent: :destroy).
    puts ''
    puts '4. Deleting most recent bill-free rotation to trigger create_rotations...'

    # Fix orphaned meals first (rotation_id = nil blocks create_rotations).
    orphaned = community.meals.where(rotation_id: nil)
    if orphaned.any?
      nearest = community.rotations.where.not(start_date: nil).order(start_date: :desc).first!
      count = orphaned.update_all(rotation_id: nearest.id)
      puts "   Assigned #{count} orphaned meals to rotation #{nearest.id}."
    end

    # Walk backwards from the most recent rotation to find one safe to delete.
    safe_rotation = community.rotations
                             .where.not(start_date: nil)
                             .order(start_date: :desc)
                             .detect { |r| r.meals.joins(:bills).none? }

    if safe_rotation
      meal_count = safe_rotation.meals.count
      safe_rotation.meals.destroy_all
      safe_rotation.destroy!
      puts "   Deleted rotation #{safe_rotation.id} (start=#{safe_rotation.start_date}, #{meal_count} meals)."
      puts '   create_rotations will recreate it. notify_new will announce it.'
    else
      puts '   WARNING: All recent rotations have billed meals. Skipping deletion.'
      puts '   create_rotations may be a no-op.'
    end

    # Clean up any rotations with nil start_date (garbage records with no meals).
    community.rotations.where(start_date: nil).find_each do |r|
      r.meals.destroy_all
      r.destroy!
      puts "   Cleaned up empty rotation #{r.id} (nil start_date)."
    end

    # 5. Ensure residents:notify has an upcoming rotation to work with.
    #    It requires a rotation starting within 7 days with residents_notified=false.
    puts ''
    puts '5. Ensuring residents:notify has an upcoming rotation...'
    upcoming = Rotation.where('start_date > ?', Time.zone.today)
                       .where(start_date: ...(Time.zone.today + 1.week))
                       .where(residents_notified: false)

    if upcoming.any?
      upcoming.each do |r|
        open_count = r.meals.left_joins(:bills).group(:id).having('COUNT(bills.id) < 2').count.size
        puts "   Rotation #{r.id} (start=#{r.start_date}): #{open_count} meals need cooks."
      end
    else
      # No rotation in the window — move the nearest future one into range.
      future = community.rotations
                        .where('start_date > ?', Time.zone.today + 1.week)
                        .where(residents_notified: false)
                        .order(:start_date).first
      if future
        original_date = future.start_date
        future.update_columns(start_date: Time.zone.tomorrow)
        puts "   Moved rotation #{future.id} start_date: #{original_date} -> #{Time.zone.tomorrow} (for demo)."
      else
        puts '   No eligible rotation found. residents:notify will be a no-op.'
      end
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
