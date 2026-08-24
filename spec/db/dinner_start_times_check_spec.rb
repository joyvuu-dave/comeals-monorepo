# frozen_string_literal: true

require 'rails_helper'

# Dinner start times live on communities as a jsonb array of seven "HH:MM"
# strings. The model validation is the first line of defense; this CHECK
# makes PostgreSQL itself refuse writes that skip the model (update_all,
# update_columns, rake tasks, psql).
RSpec.describe 'communities dinner-start-times check constraint' do
  let(:community) { create(:community) }

  def write(value)
    community.update_columns(dinner_start_times: value)
  end

  it 'allows seven 24-hour clock times' do
    expect { write(%w[18:00 19:00 19:00 19:00 19:00 19:00 23:59]) }.not_to raise_error
  end

  it 'refuses fewer than seven' do
    expect { write(%w[19:00]) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_dinner_start_times_shape/)
  end

  it 'refuses an hour past 23' do
    expect { write(%w[19:00 19:00 19:00 24:00 19:00 19:00 19:00]) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_dinner_start_times_shape/)
  end

  it 'refuses a time that is not zero-padded' do
    expect { write(%w[7:00 19:00 19:00 19:00 19:00 19:00 19:00]) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_dinner_start_times_shape/)
  end

  it 'refuses a number where a string belongs' do
    expect { write([19, '19:00', '19:00', '19:00', '19:00', '19:00', '19:00']) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_dinner_start_times_shape/)
  end

  it 'refuses something that is not an array' do
    expect { write({ '0' => '19:00' }) }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_dinner_start_times_shape/)
  end
end
