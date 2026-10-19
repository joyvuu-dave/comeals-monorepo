# frozen_string_literal: true

require 'rails_helper'

# The coverage count leaves out every migration dated at or before
# PRODUCTION_SCHEMA_VERSION, because production has run those. That is true
# only if no migration production has not run is dated that early, so a new
# migration given an old date is refused here. db/production_migrations.txt
# says how to update the list after a deploy.
RSpec.describe 'db/production_migrations.txt' do
  let(:versions_on_disk) do
    Rails.root.glob('db/migrate/*.rb').map { |path| Integer(path.basename.to_s[/\A\d+/], 10) }
  end

  def unrun_but_old(versions)
    versions.select { |version| version <= PRODUCTION_SCHEMA_VERSION } - PRODUCTION_MIGRATIONS
  end

  it 'lists every migration file dated at or before the newest one production ran' do
    found = unrun_but_old(versions_on_disk)

    expect(found).to be_empty, "#{found.sort.join(', ')}: production has not run these, so date " \
                               "each one after #{PRODUCTION_SCHEMA_VERSION}"
  end

  # A real file would be a pending migration, which stops the suite
  # before any example runs, so the new file is a number here.
  it 'would find a new migration dated before production\'s newest one, but not one dated after' do
    early = PRODUCTION_SCHEMA_VERSION - 1
    late = PRODUCTION_SCHEMA_VERSION + 1

    expect(unrun_but_old(versions_on_disk + [early, late])).to eq([early])
  end

  it 'names only migrations that are in db/migrate/, oldest first' do
    expect(PRODUCTION_MIGRATIONS - versions_on_disk).to be_empty
    expect(PRODUCTION_MIGRATIONS).to eq(PRODUCTION_MIGRATIONS.sort.uniq)
  end
end
