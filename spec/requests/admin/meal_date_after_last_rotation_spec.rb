# frozen_string_literal: true

require 'rails_helper'

# The admin New Meal form and the meal edit form refuse a date after the
# last meal of the calendar, which is the end of the last rotation
# (#143). The nightly EnsureRotationsJob starts each new rotation the day
# after the last meal. With a meal after the end, it would skip every
# schedule day between the end and that meal, and those days would never
# get a meal. The rule is only for the two forms: the job is what makes
# the meals after the end (spec/jobs/ensure_rotations_job_spec.rb).
RSpec.describe 'Admin meal forms: a date after the last rotation' do
  include ActiveSupport::Testing::TimeHelpers

  let(:community) { create(:community) }
  let(:admin_user) { create(:admin_user, community: community, superuser: true) }

  before do
    host! 'admin.example.com'
    sign_in admin_user
  end

  def create_meal(date, rotation_id:)
    post '/meals', params: { meal: { date: date.iso8601, closed: '0', rotation_id: rotation_id } }
  end

  def move_meal(meal, date)
    patch "/meals/#{meal.id}", params: { meal: { date: date.iso8601 } }
  end

  # Every sentence in the form's list of errors.
  def form_errors
    response.parsed_body.css('ul.errors li').map(&:text)
  end

  context 'with a calendar that ends on Mar 3, 2027' do
    let(:rotation) { create(:rotation, community: community) }
    let(:end_date) { Date.new(2027, 3, 3) }
    let!(:first_meal) { create(:meal, community: community, rotation: rotation, date: Date.new(2027, 2, 24)) }
    let!(:last_meal) { create(:meal, community: community, rotation: rotation, date: end_date) }
    let(:refusal) do
      'This date is after the last rotation, which ends Mar 3, 2027. ' \
        'Add the meal once the calendar reaches that date.'
    end

    describe 'the New Meal form' do
      it 'refuses a date after the end, says why, and saves nothing' do
        expect { create_meal(end_date + 1, rotation_id: rotation.id) }.not_to change(Meal, :count)

        expect(response).to have_http_status(:ok)
        expect(form_errors).to eq([refusal])
      end

      it 'saves a gap date before the end' do
        expect { create_meal(end_date - 1, rotation_id: rotation.id) }.to change(Meal, :count).by(1)

        expect(response).to redirect_to("/meals/#{Meal.find_by!(date: end_date - 1).id}")
      end

      # The end date is not after the end. The last meal is on it, so the
      # one refusal is the one for a date another meal has.
      it 'does not call the end date itself after the end' do
        expect { create_meal(end_date, rotation_id: rotation.id) }.not_to change(Meal, :count)

        expect(form_errors).to eq(['Date has already been taken'])
      end

      # No date is not a date after the end, and not a 500 either.
      it 'says only that the date is missing when there is none' do
        post '/meals', params: { meal: { date: '', closed: '0', rotation_id: rotation.id } }

        expect(response).to have_http_status(:ok)
        expect(form_errors).to eq(["Date can't be blank"])
      end
    end

    describe 'the meal edit form' do
      it 'refuses to move the last meal to a later date, and keeps its date' do
        move_meal(last_meal, end_date + 7)

        expect(response).to have_http_status(:ok)
        expect(form_errors).to eq([refusal])
        expect(last_meal.reload.date).to eq(end_date)
      end

      it 'refuses to move another meal after the end' do
        move_meal(first_meal, end_date + 1)

        expect(form_errors).to eq([refusal])
        expect(first_meal.reload.date).to eq(Date.new(2027, 2, 24))
      end

      # The last meal counts at the date it has before the edit. So it can
      # move to any earlier day, also a day after the meal before it: the
      # job then starts the next rotation the day after its new date, and
      # no schedule day is skipped.
      it 'moves the last meal to an earlier date' do
        move_meal(last_meal, end_date - 1)

        expect(response).to redirect_to("/meals/#{last_meal.id}")
        expect(last_meal.reload.date).to eq(end_date - 1)
      end

      it 'moves a meal to a gap date before the end' do
        move_meal(first_meal, Date.new(2027, 2, 25))

        expect(response).to redirect_to("/meals/#{first_meal.id}")
        expect(first_meal.reload.date).to eq(Date.new(2027, 2, 25))
      end

      # A change that leaves the date alone is not a new date.
      it 'saves other changes to the last meal' do
        patch "/meals/#{last_meal.id}", params: { meal: { closed: '1' } }

        expect(response).to redirect_to("/meals/#{last_meal.id}")
        expect(last_meal.reload).to be_closed
      end
    end
  end

  # With no meal at all there is no end to be after. The New Meal form
  # needs a rotation, so this is a rotation whose meals were all deleted.
  it 'saves any date when the calendar has no meals' do
    rotation = create(:rotation, community: community)

    expect { create_meal(Date.new(2027, 3, 4), rotation_id: rotation.id) }.to change(Meal, :count).by(1)
    expect(response).to redirect_to("/meals/#{Meal.find_by!(date: Date.new(2027, 3, 4)).id}")
  end

  # The two failing specs from #143. Each made a meal 60 days after the
  # last rotation, one with the New Meal form and one by moving the last
  # meal with the edit form. Four months later the job made rotations
  # again, starting the day after that meal, and two months of schedule
  # days between the old end and that meal never got a meal. The forms
  # now refuse that date, so the job fills every one of those days.
  describe 'the nightly job, after an admin tried a date after the end' do
    before { travel_to(Time.zone.local(2026, 1, 15, 12)) { EnsureRotationsJob.perform_now } }

    let(:last_scheduled) { community.meals.maximum(:date) }
    let(:tried) { last_scheduled + 60 }

    def expect_no_schedule_day_without_a_meal
      # Six months from today is past the date the admin tried, so the
      # job makes rotations again.
      travel_to(Time.zone.local(2026, 5, 15, 12)) do
        expect { EnsureRotationsJob.perform_now }.to change(Rotation, :count)
      end

      missing = community.meal_schedule.dates_between(last_scheduled + 1, tried - 1) - community.meals.pluck(:date)
      expect(missing).to be_empty
    end

    it 'fills the schedule when the New Meal form was asked for a one-off meal after the end' do
      create_meal(tried, rotation_id: Rotation.order(:id).last.id)
      refused_with = form_errors

      expect_no_schedule_day_without_a_meal
      expect(refused_with).to contain_exactly(a_string_starting_with('This date is after the last rotation'))
    end

    it 'fills the schedule when the edit form was asked to move the last meal after the end' do
      move_meal(community.meals.order(:date).last, tried)
      refused_with = form_errors

      expect_no_schedule_day_without_a_meal
      expect(refused_with).to contain_exactly(a_string_starting_with('This date is after the last rotation'))
    end
  end
end
