# frozen_string_literal: true

require 'rails_helper'

# Issue #287. The admin meal form is built from one read of the meal, and
# the save comes in a later request. A cook can close the meal or change
# its max on the meal page in between. Before this, the admin save sent
# the form's closed and max back and wrote them over the cook's change,
# with no error: the meal was open again and its max was gone.
#
# Now the form sends the date, closed and max it showed, in hidden
# shown[...] fields, and a save is refused when any of them has changed
# since. A sign-up does not refuse it: it changes none of the three.
#
# Meals have no lock_version on purpose. Bills, sign-ups and guests
# `touch` their meal, and touch adds one to lock_version and checks the
# version in memory, so every sign-up would refuse an open form, and a
# sign-up holding an older meal would raise StaleObjectError.
#
# The same file covers a guest removed on the meal page while the form is
# open: the form's nested guest row names a guest that is gone.
RSpec.describe 'Admin meal changed by someone else' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:superuser) { create(:admin_user, community: community, superuser: true) }
  let(:host) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:meal) { create(:meal, community: community) }

  before do
    host! 'admin.example.com'
    sign_in superuser
  end

  def open_form
    get "/meals/#{meal.id}/edit"
    response.parsed_body
  end

  def shown_values(page)
    %w[date closed max].index_with { |key| page.at_css("input[type=hidden][name='shown[#{key}]']")&.[]('value') }
  end

  it 'puts the date, closed and max it was built from on the edit form' do
    meal.update!(closed: true, max: 12)

    expect(shown_values(open_form)).to eq('date' => meal.date.iso8601, 'closed' => 'true', 'max' => '12')
  end

  it 'shows an empty max for a meal with none' do
    expect(shown_values(open_form)).to eq('date' => meal.date.iso8601, 'closed' => 'false', 'max' => '')
  end

  context 'when the cook closes the meal with a max after the form was opened' do
    let!(:shown) { shown_values(open_form) }
    let(:new_date) { meal.date - 1 }

    before do
      meal.update!(closed: true, max: 12)
      patch "/meals/#{meal.id}", params: { shown: shown, meal: { date: new_date.iso8601, closed: '0' } }
    end

    it "keeps the cook's change" do
      expect(meal.reload).to have_attributes(date: new_date + 1, closed: true, max: 12)
    end

    it 'says so, and shows the form again with the meal as it is now' do
      expect(response).to redirect_to("/meals/#{meal.id}/edit")
      expect(flash[:alert]).to eq('Someone else changed this meal after you opened it. Nothing was saved. ' \
                                  'This form now shows the meal as it is. Make your change again.')
      follow_redirect!
      expect(shown_values(response.parsed_body)).to include('closed' => 'true', 'max' => '12')
    end
  end

  it 'refuses a save from a form that showed another max' do
    meal.update!(closed: true, max: 12)
    shown = shown_values(open_form)
    meal.update!(max: 15)

    patch "/meals/#{meal.id}", params: { shown: shown, meal: { closed: '1', max: '12' } }

    expect(response).to redirect_to("/meals/#{meal.id}/edit")
    expect(meal.reload.max).to eq(15)
  end

  it 'refuses a save from a form that showed another date' do
    shown = shown_values(open_form)
    meal.update!(date: meal.date - 2)

    patch "/meals/#{meal.id}", params: { shown: shown, meal: { closed: '1', max: '10' } }

    expect(response).to redirect_to("/meals/#{meal.id}/edit")
    expect(meal.reload.closed).to be(false)
  end

  it 'saves when only a sign-up changed after the form was opened' do
    shown = shown_values(open_form)
    create(:meal_resident, meal: meal, resident: host)

    patch "/meals/#{meal.id}", params: { shown: shown, meal: { closed: '1', max: '10' } }

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload).to have_attributes(closed: true, max: 10)
  end

  it 'saves a form from the current meal (control)' do
    patch "/meals/#{meal.id}", params: { shown: shown_values(open_form), meal: { closed: '1', max: '10' } }

    expect(response).to redirect_to("/meals/#{meal.id}")
    expect(meal.reload).to have_attributes(closed: true, max: 10)
  end

  # The meal itself deleted while the save waited for its lock: with_lock
  # reads it again and finds nothing. That is not about a guest, so it is
  # the plain "not found" error (a 404 page in production), not the guest
  # sentence.
  it 'lets a missing meal raise, not answer with the guest sentence' do
    shown = shown_values(open_form)
    # rubocop:disable-next RSpec/AnyInstance
    allow_any_instance_of(Meal).to receive(:with_lock).and_raise(ActiveRecord::RecordNotFound.new('gone', 'Meal'))

    expect { patch "/meals/#{meal.id}", params: { shown: shown, meal: { closed: '1', max: '10' } } }
      .to raise_error(ActiveRecord::RecordNotFound) { |e| expect(e.model).to eq('Meal') }
  end

  context 'when a guest on the form is removed after the form was opened' do
    let!(:guest) { create(:guest, meal: meal, resident: host) }
    let!(:shown) { shown_values(open_form) }

    before do
      guest.destroy!
      patch "/meals/#{meal.id}", params: {
        shown: shown,
        meal: { closed: '1', max: '10',
                guests_attributes: { '0' => { id: guest.id, multiplier: 2, resident_id: host.id, _destroy: '0' } } }
      }
    end

    it 'saves nothing, says why, and shows the form again' do
      expect(meal.reload).to have_attributes(closed: false, max: nil)
      expect(response).to redirect_to("/meals/#{meal.id}/edit")
      expect(flash[:alert]).to eq('A guest on this form was removed after you opened it. Nothing was saved. ' \
                                  'This form now shows the meal as it is. Make your change again.')
    end
  end
end
