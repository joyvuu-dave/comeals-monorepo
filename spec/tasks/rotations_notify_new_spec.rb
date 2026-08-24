# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'rotations:notify_new', type: :task do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  before do
    stub_const('BROADCAST_EMAIL_ENABLED', true)
  end

  after do
    Rake::Task['rotations:notify_new'].reenable
  end

  it 'sends nothing when broadcast email is disabled' do
    stub_const('BROADCAST_EMAIL_ENABLED', false)
    create(:resident, community: community, unit: unit, active: true)
    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 100.days }]
    rotation = Rotation.create!(meals_attributes: attrs)

    initial_count = ActionMailer::Base.deliveries.size
    Rake::Task['rotations:notify_new'].invoke

    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
    expect(rotation.reload.new_rotation_notified_at).to be_nil
  end

  it 'skips rotations created more than 7 days ago, so re-enabling cannot flood' do
    create(:resident, community: community, unit: unit, active: true)
    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 100.days }]
    stale = Rotation.create!(meals_attributes: attrs)
    stale.update_column(:created_at, 8.days.ago)

    initial_count = ActionMailer::Base.deliveries.size
    Rake::Task['rotations:notify_new'].invoke

    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
    expect(stale.reload.new_rotation_notified_at).to be_nil
  end

  it 'sends new-rotation emails for rotations not yet notified' do
    create(:resident, community: community, unit: unit, active: true)
    meal = create(:meal, community: community)
    attrs = [{ date: meal.date + 100.days }]
    rotation = Rotation.create!(meals_attributes: attrs)

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
    attrs = [{ date: meal.date + 200.days }]
    rotation = Rotation.create!(meals_attributes: attrs)
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
    attrs = [{ date: meal.date + 300.days }]
    Rotation.create!(meals_attributes: attrs)

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
    rotation = Rotation.create!(no_email: true)

    # no_email sets new_rotation_notified_at immediately
    rotation.reload
    expect(rotation.new_rotation_notified_at).to be_present

    initial_count = ActionMailer::Base.deliveries.size
    Rake::Task['rotations:notify_new'].invoke

    # No emails sent
    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
  end

  describe 'rotations:notify_new when the run is not complete' do
    before(:all) { RakeTasks.ensure_loaded }

    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }

    before { stub_const('BROADCAST_EMAIL_ENABLED', true) }

    after { Rake::Task['rotations:notify_new'].reenable }

    it 'mails only the people it missed on the next run, then stamps the rotation' do
      residents = %w[Ann Bob Cid].map do |name|
        create(:resident, community: community, unit: unit, active: true, name: name,
                          email: "#{name.downcase}@example.com")
      end
      meal = create(:meal, community: community)
      rotation = Rotation.create!(meals_attributes: [{ date: meal.date + 100.days }])
      stub_const('PacedDelivery::CAP', 2)
      allow(Rails.logger).to receive(:error)

      Rake::Task['rotations:notify_new'].invoke
      first_run = ActionMailer::Base.deliveries.select { |m| m.subject == 'New Rotation Posted' }.map(&:to).flatten
      expect(first_run.size).to eq(2)
      expect(rotation.reload.new_rotation_notified_at).to be_nil

      Rake::Task['rotations:notify_new'].reenable
      Rake::Task['rotations:notify_new'].invoke
      all = ActionMailer::Base.deliveries.select { |m| m.subject == 'New Rotation Posted' }.map(&:to).flatten
      expect(all).to match_array(residents.map(&:email))
      expect(rotation.reload.new_rotation_notified_at).to be_present
    end

    it 'does not stamp the rotation notified when a mail failed, so the next run tries again' do
      create(:resident, community: community, unit: unit, active: true)
      meal = create(:meal, community: community)
      rotation = Rotation.create!(meals_attributes: [{ date: meal.date + 100.days }])
      allow(PacedDelivery).to receive(:deliver).and_return(PacedDelivery::Result.new(sent: 0, failed: 1, skipped: 0))
      allow(Rails.logger).to receive(:error)

      Rake::Task['rotations:notify_new'].invoke

      expect(rotation.reload.new_rotation_notified_at).to be_nil
      expect(Rails.logger).to have_received(:error).with(/1 email\(s\) failed.*not marking as notified/)
    end
  end
end
