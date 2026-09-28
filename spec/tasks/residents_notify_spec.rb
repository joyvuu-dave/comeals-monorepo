# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe 'residents:notify' do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    RakeTasks.ensure_loaded
  end

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  before do
    stub_const('BROADCAST_EMAIL_ENABLED', true)
  end

  after do
    Rake::Task['residents:notify'].reenable
  end

  # start_date is the first meal's date, read from the meals; so the first
  # meal is created on it.
  def create_rotation_with_meals(community:, start_date:, residents_notified: false, meal_dates: nil)
    rotation = create(:rotation, community: community,
                                 residents_notified: residents_notified)
    dates = meal_dates || [start_date]
    dates.each do |date|
      create(:meal, community: community, rotation: rotation, date: date)
    end
    rotation
  end

  it 'sends nothing when broadcast email is disabled' do
    stub_const('BROADCAST_EMAIL_ENABLED', false)
    rotation = create_rotation_with_meals(community: community,
                                          start_date: community.today + 3.days)
    create(:resident, community: community, unit: unit,
                      can_cook: true, active: true, multiplier: 2)

    initial_count = ActionMailer::Base.deliveries.size
    Rake::Task['residents:notify'].invoke

    expect(ActionMailer::Base.deliveries.size).to eq(initial_count)
    expect(rotation.reload.residents_notified).to be false
  end

  it 'sends signup emails to eligible cooks who have not signed up' do
    rotation = create_rotation_with_meals(community: community,
                                          start_date: community.today + 3.days)

    eligible = create(:resident, community: community, unit: unit,
                                 can_cook: true, active: true, multiplier: 2)

    Rake::Task['residents:notify'].invoke

    emails = ActionMailer::Base.deliveries
    expect(emails.map(&:to).flatten).to include(eligible.email)
    expect(emails.last.subject).to eq('Sign up to Cook')
    expect(rotation.reload.residents_notified).to be true
  end

  it 'does not email residents who are already signed up to cook' do
    rotation = create_rotation_with_meals(community: community,
                                          start_date: community.today + 3.days)
    meal = rotation.meals.first

    signed_up = create(:resident, community: community, unit: unit,
                                  can_cook: true, active: true, multiplier: 2)
    create(:bill, meal: meal, resident: signed_up, community: community)

    not_signed_up = create(:resident, community: community, unit: unit,
                                      can_cook: true, active: true, multiplier: 2)

    Rake::Task['residents:notify'].invoke

    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    expect(recipients).to include(not_signed_up.email)
    expect(recipients).not_to include(signed_up.email)
  end

  it 'excludes residents who cannot cook or are inactive' do
    create_rotation_with_meals(community: community,
                               start_date: community.today + 3.days)

    cannot_cook = create(:resident, community: community, unit: unit,
                                    can_cook: false, active: true, multiplier: 2)
    inactive = create(:resident, community: community, unit: unit,
                                 can_cook: true, active: false, multiplier: 2)
    child = create(:resident, community: community, unit: unit,
                              can_cook: true, active: true, multiplier: 1)

    Rake::Task['residents:notify'].invoke

    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    expect(recipients).not_to include(cannot_cook.email)
    expect(recipients).not_to include(inactive.email)
    expect(recipients).not_to include(child.email)
  end

  # Open means fewer than 2 cooks. A meal with no cook at all is open too:
  # only the left join keeps it in the list.
  it 'correctly identifies open meals (fewer than 2 cooks)' do
    no_cook_date = community.today + 3.days
    open_date = community.today + 4.days
    full_date = community.today + 5.days
    rotation = create_rotation_with_meals(community: community,
                                          start_date: no_cook_date,
                                          meal_dates: [full_date, open_date, no_cook_date])

    open_meal = rotation.meals.find_by(date: open_date)
    full_meal = rotation.meals.find_by(date: full_date)

    cook1 = create(:resident, community: community, unit: unit)
    create(:bill, meal: open_meal, resident: cook1, community: community)

    cook2 = create(:resident, community: community, unit: unit)
    cook3 = create(:resident, community: community, unit: unit)
    create(:bill, meal: full_meal, resident: cook2, community: community)
    create(:bill, meal: full_meal, resident: cook3, community: community)

    eligible = create(:resident, community: community, unit: unit,
                                 can_cook: true, active: true, multiplier: 2)

    Rake::Task['residents:notify'].invoke

    email = ActionMailer::Base.deliveries.find { |e| e.to.include?(eligible.email) }
    expect(email).to be_present
    # The open dates, oldest first, in both parts of the mail.
    expect(email.text_part.body.to_s.scan(/\d{4}-\d{2}-\d{2}/)).to eq([no_cook_date.to_s, open_date.to_s])
    expect(email.html_part.body.to_s.scan(%r{<li>(\d{4}-\d{2}-\d{2})</li>}).flatten)
      .to eq([no_cook_date.to_s, open_date.to_s])
  end

  it 'skips rotations that do not start within the next week' do
    rotation = create_rotation_with_meals(community: community,
                                          start_date: community.today + 2.weeks)
    create(:resident, community: community, unit: unit,
                      can_cook: true, active: true, multiplier: 2)

    Rake::Task['residents:notify'].invoke

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(rotation.reload.residents_notified).to be false
  end

  # The week is counted from the community's today. At 09:00 UTC on
  # 2026-01-16 it is January 16 in the app's zone (Los Angeles) and still
  # January 15 in Honolulu. A rotation that starts on January 16 starts
  # tomorrow for the community, inside the window. Counted from the app
  # zone's today it starts today, which the window leaves out.
  it "counts the week from the community's today" do
    community.update!(timezone: 'Pacific/Honolulu')
    travel_to(Time.utc(2026, 1, 16, 9, 0)) do
      rotation = create_rotation_with_meals(community: community, start_date: Date.new(2026, 1, 16))
      cook = create(:resident, community: community, unit: unit, can_cook: true, active: true, multiplier: 2)
      expect(Time.zone.today).to eq(Date.new(2026, 1, 16))

      Rake::Task['residents:notify'].invoke

      expect(ActionMailer::Base.deliveries.flat_map(&:to)).to eq([cook.email])
      expect(rotation.reload.residents_notified).to be true
    end
  end

  it 'skips eligible cooks who have no email address' do
    rotation = create_rotation_with_meals(community: community,
                                          start_date: community.today + 3.days)

    with_email = create(:resident, community: community, unit: unit,
                                   can_cook: true, active: true, multiplier: 2)
    without_email = create(:resident, community: community, unit: unit,
                                      can_cook: true, active: true, multiplier: 2)
    without_email.update_column(:email, nil)

    Rake::Task['residents:notify'].invoke

    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    expect(recipients).to include(with_email.email)
    expect(recipients).not_to include(nil)
    expect(rotation.reload.residents_notified).to be true
  end

  it 'skips rotations already marked as notified' do
    create_rotation_with_meals(community: community,
                               start_date: community.today + 3.days,
                               residents_notified: true)
    create(:resident, community: community, unit: unit,
                      can_cook: true, active: true, multiplier: 2)

    Rake::Task['residents:notify'].invoke

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  describe 'residents:notify when the run is not complete' do
    before(:all) { RakeTasks.ensure_loaded }

    let(:community) { create(:community) }
    let(:unit) { create(:unit, community: community) }

    before { stub_const('BROADCAST_EMAIL_ENABLED', true) }

    after { Rake::Task['residents:notify'].reenable }

    def rotation_starting_in(days)
      rotation = create(:rotation, community: community)
      create(:meal, community: community, rotation: rotation, date: community.today + days)
      rotation
    end

    it 'does not mark the rotation notified when a mail failed, so the next run tries again' do
      rotation = rotation_starting_in(3)
      create(:resident, community: community, unit: unit, can_cook: true, active: true, multiplier: 2,
                        email: 'cook@example.com')
      allow(PacedDelivery).to receive(:deliver).and_return(PacedDelivery::Result.new(sent: 0, failed: 1, skipped: 0))
      allow(Rails.logger).to receive(:error)

      Rake::Task['residents:notify'].invoke

      expect(rotation.reload.residents_notified).to be(false)
      expect(Rails.logger).to have_received(:error).with(/1 email\(s\) failed.*not marking as notified/)
    end

    it 'mails the rest on the next run, once, and only then marks the rotation notified' do
      rotation = rotation_starting_in(3)
      cooks = %w[Ann Bob Cid].map do |name|
        create(:resident, community: community, unit: unit, can_cook: true, active: true, multiplier: 2,
                          name: name, email: "#{name.downcase}@example.com")
      end
      stub_const('PacedDelivery::CAP', 2)
      allow(Rails.logger).to receive(:error)

      before = ActionMailer::Base.deliveries.size
      Rake::Task['residents:notify'].invoke
      first_run = ActionMailer::Base.deliveries.drop(before).map(&:to).flatten
      expect(first_run.size).to eq(2)
      expect(rotation.reload.residents_notified).to be(false)

      Rake::Task['residents:notify'].reenable
      Rake::Task['residents:notify'].invoke
      second_run = ActionMailer::Base.deliveries.drop(before + 2).map(&:to).flatten
      expect(second_run.size).to eq(1)
      expect(first_run + second_run).to match_array(cooks.map(&:email))
      expect(rotation.reload.residents_notified).to be(true)
      expect(MailDelivery.where(about: rotation).count).to eq(3)
    end

    it 'does not mark the rotation notified when the per-run cap cut the list short' do
      rotation = rotation_starting_in(3)
      create(:resident, community: community, unit: unit, can_cook: true, active: true, multiplier: 2,
                        email: 'cook@example.com')
      allow(PacedDelivery).to receive(:deliver).and_return(PacedDelivery::Result.new(sent: 100, failed: 0, skipped: 3))
      allow(Rails.logger).to receive(:error)

      Rake::Task['residents:notify'].invoke

      expect(rotation.reload.residents_notified).to be(false)
      expect(Rails.logger).to have_received(:error).with(/3 over the cap/)
    end
  end
end
