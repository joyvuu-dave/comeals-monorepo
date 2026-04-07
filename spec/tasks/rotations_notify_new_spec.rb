# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'rotations:notify_new', type: :task do
  before(:all) do
    Rails.application.load_tasks
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  after do
    Rake::Task['rotations:notify_new'].reenable
  end

  before do
    allow(Pusher).to receive(:trigger)
  end

  it 'sends new-rotation emails for rotations not yet notified' do
    create(:resident, community: community, unit: unit, active: true)
    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 100.days, community_id: community.id }]
    rotation = Rotation.create!(community_id: community.id,
                                meals_attributes: attrs)

    expect(rotation.new_rotation_notified_at).to be_nil

    Rake::Task['rotations:notify_new'].invoke

    rotation.reload
    expect(rotation.new_rotation_notified_at).to be_present
    new_emails = ActionMailer::Base.deliveries.count do |m|
      m.subject == 'New Rotation Posted'
    end
    expect(new_emails).to be >= 1
  end

  it 'skips rotations that are already notified' do
    create(:resident, community: community, unit: unit, active: true)
    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 200.days, community_id: community.id }]
    rotation = Rotation.create!(community_id: community.id,
                                meals_attributes: attrs)
    rotation.update_column(:new_rotation_notified_at, 1.day.ago)

    initial_count = ActionMailer::Base.deliveries.size

    Rake::Task['rotations:notify_new'].invoke

    # No new emails sent for already-notified rotation
    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
  end

  it 'skips inactive residents and residents without email' do
    create(:resident, community: community, unit: unit,
                      active: true, email: 'active@test.com')
    create(:resident, community: community, unit: unit,
                      active: false, can_cook: false, email: nil)
    create(:resident, community: community, unit: unit,
                      active: true, multiplier: 1, email: nil)

    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 300.days, community_id: community.id }]
    Rotation.create!(community_id: community.id, meals_attributes: attrs)

    Rake::Task['rotations:notify_new'].invoke

    # Only the active resident with email should receive the notification
    new_rotation_emails = ActionMailer::Base.deliveries.select do |m|
      m.subject == 'New Rotation Posted'
    end
    recipients = new_rotation_emails.flat_map(&:to)
    expect(recipients).to include('active@test.com')
    expect(recipients).not_to include(nil)
  end

  it 'suppresses notification for rotations created with no_email' do
    create(:resident, community: community, unit: unit, active: true)
    # Simulate auto_create_rotations behavior
    rotation = Rotation.create!(community_id: community.id,
                                no_email: true)

    # no_email sets new_rotation_notified_at immediately
    rotation.reload
    expect(rotation.new_rotation_notified_at).to be_present

    initial_count = ActionMailer::Base.deliveries.size
    Rake::Task['rotations:notify_new'].invoke

    # No emails sent
    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
  end
end
