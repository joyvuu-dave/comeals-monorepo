# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# bin/lib/schema-check: the release phase's rule
# (lib/squashed_migrations_check.rb) for the bash scripts that read a
# database before they change anything, bin/deploy and
# bin/lib/rollback/check-backup (#248). Run as those scripts run it: with
# no environment but a PATH, so it must find its gems by itself.
RSpec.describe 'bin/lib/schema-check' do
  let(:dir) { Dir.mktmpdir('schema-check') }
  let(:version_file) { File.join(dir, 'version.txt').tap { File.write(it, "# a comment\n20261023140000\n") } }
  let(:structure) do
    File.join(dir, 'structure.sql').tap do |path|
      File.write(path, "-- — a dash\nINSERT INTO \"schema_migrations\" (version) VALUES\n" \
                       "('20261023140000'),\n('20170515164827');\n")
    end
  end

  after { FileUtils.remove_entry(dir) }

  def check(input, *args)
    args = [version_file, structure] if args.empty?
    env = { 'PATH' => '/usr/bin:/bin', 'HOME' => dir }
    out, status = Open3.capture2e(env, RbConfig.ruby, Rails.root.join('bin/lib/schema-check').to_s, *args,
                                  stdin_data: input, unsetenv_others: true)
    [out, status.exitstatus]
  end

  it 'passes a database that has run every deleted migration, and names its newest' do
    expect(check(" version=20170515164827\n version=20261023140000\n table=meals\n end=ok\n(4 rows)\n"))
      .to eq(["newest=20261023140000\n", 0])
  end

  it 'passes a database with no tables' do
    expect(check("end=ok\n")).to eq(["new\n", 0])
  end

  it 'refuses a database missing an older deleted migration, in the release phase\'s words' do
    out, status = check("version=20261023140000\ntable=meals\nend=ok\n")

    expect(status).to eq(1)
    expect(out).to start_with('The database has not run 1 of the migrations that were deleted from db/migrate/ ' \
                              'after production ran them: 20170515164827.')
  end

  it 'refuses a database that is behind the file' do
    out, status = check("version=20170515164827\nend=ok\n")

    expect(status).to eq(1)
    expect(out).to start_with('The database is behind db/production_schema_version.txt.')
  end

  it 'refuses a database with tables but no versions' do
    out, status = check("table=meals\ntable=schema_migrations\nend=ok\n")

    expect(status).to eq(1)
    expect(out).to start_with('The database has tables (meals, schema_migrations) but no record')
  end

  # A read that stopped part way must not look like a database with no
  # tables, which passes.
  it 'cannot read a list with no end=ok line' do
    expect(check("table=meals\n"))
      .to eq(["The list of tables and migrations ended part way: it has no end=ok line.\n", 2])
  end

  it 'cannot read a version file that does not hold one version' do
    File.write(version_file, "# only a comment\n")

    expect(check("end=ok\n"))
      .to eq(["db/production_schema_version.txt must hold one version, not []\n", 2])
  end

  it 'cannot read a structure file with no list' do
    File.write(structure, "CREATE TABLE meals ();\n")

    expect(check("end=ok\n")).to eq(["db/structure.sql has no INSERT INTO schema_migrations list\n", 2])
  end

  it 'cannot read a file that is not there' do
    out, status = check("end=ok\n", File.join(dir, 'missing.txt'), structure)

    expect([out, status]).to match([/No such file or directory/, 2])
  end

  it 'says how to call it when it is given the wrong number of files' do
    expect(check("end=ok\n", version_file))
      .to eq(["Usage: bin/lib/schema-check VERSION_FILE STRUCTURE_FILE < lines\n", 2])
  end
end
