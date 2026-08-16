# frozen_string_literal: true

require 'rails_helper'

# Issue #58: the child pricing ages live on communities. The Community model
# validations are the first line of defense; these CHECK constraints make
# PostgreSQL itself refuse writes that skip the model (update_all,
# update_columns, rake tasks, psql).
RSpec.describe 'communities child-pricing-ages check constraints' do
  let(:community) { create(:community) }

  it 'refuses a validation-skipping negative age' do
    expect do
      community.update_columns(free_below_age: -1)
    end.to raise_error(ActiveRecord::StatementInvalid, /communities_child_ages_non_negative/)
  end

  it 'refuses a validation-skipping free-below age above the full-price age' do
    expect do
      community.update_columns(free_below_age: 13, full_price_age: 12)
    end.to raise_error(ActiveRecord::StatementInvalid, /communities_child_ages_ordered/)
  end

  it 'allows equal ages' do
    expect do
      community.update_columns(free_below_age: 7, full_price_age: 7)
    end.not_to raise_error
  end
end
