# frozen_string_literal: true

require 'rails_helper'

# The community's zone must be one of Community::SUPPORTED_TIMEZONES. The
# model's validation says so on the form. This CHECK holds it for a write
# that skips the model (update_column, insert_all, psql). A zone Rails does
# not know makes ActiveSupport::TimeZone[] nil, and then Community#today
# and every date the app works out raise; the database's own triggers
# read the zone too (comeals_local_day).
RSpec.describe 'communities timezone check constraint' do
  let!(:community) { create(:community) }

  # The quoted names in the CHECK, read back from PostgreSQL.
  def names_in_the_check
    definition = Community.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'communities_timezone_supported'
    SQL
    definition.to_s.scan(/'([^']+)'/).flatten
  end

  it 'refuses a zone name Rails does not know, written past the model' do
    expect { community.update_column(:timezone, 'Not/A_Zone') }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_timezone_supported/)
  end

  it 'refuses a zone PostgreSQL and Rails both know, when the app does not offer it' do
    expect { community.update_column(:timezone, 'Asia/Kolkata') }
      .to raise_error(ActiveRecord::StatementInvalid, /communities_timezone_supported/)
  end

  it 'names the same zones as Community::SUPPORTED_TIMEZONES' do
    expect(names_in_the_check).to match_array(Community::SUPPORTED_TIMEZONES.values)
  end

  it 'accepts every supported zone, and PostgreSQL and Rails each know every one' do
    known_to_postgres = Community.connection.select_values('SELECT name FROM pg_timezone_names')
    Community::SUPPORTED_TIMEZONES.each_value do |zone|
      community.update_column(:timezone, zone)
      expect(community.reload.timezone).to eq(zone)
      expect(known_to_postgres).to include(zone)
      expect(ActiveSupport::TimeZone[zone]).not_to be_nil
    end
  end
end
