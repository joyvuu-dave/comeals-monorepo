# frozen_string_literal: true

require 'rails_helper'

# The pg_trgm extension must be present, and word_similarity must find a
# name whose typo is inside the word, where ILIKE on the first letters
# cannot. This pins both the extension and the threshold a search uses.
RSpec.describe 'pg_trgm fuzzy name search' do
  it 'is enabled' do
    expect(ActiveRecord::Base.connection.extension_enabled?('pg_trgm')).to be(true)
  end

  it 'finds a name with a typo inside the word' do
    create(:resident, name: 'Steve Safru')
    create(:resident, name: 'Bonnie Fergusson')

    names = Resident.where('word_similarity(?, name) > 0.4', 'steev')
                    .order(Arel.sql("word_similarity('steev', name) DESC"))
                    .pluck(:name)

    expect(names).to eq(['Steve Safru'])
  end
end
