# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/structure_dump_cleanup')

# pg_dump writes a COMMENT ON EXTENSION for each extension. Only the
# extension's owner may run one, and on Heroku that is rdsadmin, not the
# app's user, so a new Heroku database could not load the file (#248).
RSpec.describe StructureDumpCleanup do
  let(:extension) do
    "--\n-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -\n--\n\n" \
      "CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;\n\n\n"
  end
  let(:comment) do
    "--\n-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -\n--\n\n" \
      "COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';\n\n\n"
  end
  let(:table_comment) do
    "--\n-- Name: TABLE meals; Type: COMMENT; Schema: public; Owner: -\n--\n\n" \
      "COMMENT ON TABLE public.meals IS 'one dinner';\n\n\n"
  end

  describe '.without_extension_comments' do
    it 'removes the statement and the lines pg_dump writes above it' do
      expect(described_class.without_extension_comments(extension + comment + table_comment))
        .to eq(extension + table_comment)
    end

    # pg_dump writes one for each extension, and the app has several.
    it 'removes every one, not only the first' do
      second = comment.gsub('pgcrypto', 'btree_gist').sub('cryptographic functions', 'GiST support')

      expect(described_class.without_extension_comments(extension + comment + second + table_comment))
        .to eq(extension + table_comment)
    end

    it 'keeps comments on tables, columns and everything else' do
      expect(described_class.without_extension_comments(table_comment)).to eq(table_comment)
    end

    # A quote inside the text is written as two quotes.
    it 'removes one whose text holds a quote, and one with no lines above it' do
      text = "#{extension}COMMENT ON EXTENSION \"uuid-ossp\" IS 'it''s for ids';\n#{table_comment}"

      expect(described_class.without_extension_comments(text)).to eq(extension + table_comment)
    end

    it 'leaves a file with none as it is' do
      expect(described_class.without_extension_comments(extension)).to eq(extension)
    end
  end

  describe '.clean!' do
    it 'does not write a file that has none' do
      Dir.mktmpdir('structure') do |dir|
        path = File.join(dir, 'structure.sql')
        File.write(path, extension)
        File.chmod(0o444, path)

        expect { described_class.clean!(path) }.not_to raise_error
        expect(File.read(path)).to eq(extension)
      end
    end

    # The file is UTF-8 whatever the process's default encoding is. A
    # process started with no UTF-8 locale has US-ASCII as its default.
    # clean! reads the file as UTF-8, but writes it in the default, so a
    # character outside ASCII stops the write.
    it 'writes the file as UTF-8 when the default encoding is not' do
      Dir.mktmpdir('structure') do |dir|
        path = File.join(dir, 'structure.sql')
        accented = table_comment.sub('one dinner', 'one dinner, café included')
        File.write(path, extension + comment + accented)
        default = Encoding.default_external

        begin
          Encoding.default_external = Encoding::US_ASCII
          described_class.clean!(path)
        ensure
          Encoding.default_external = default
        end

        expect(File.read(path, encoding: 'UTF-8')).to eq(extension + accented)
      end
    end

    it 'rewrites the file without them' do
      Dir.mktmpdir('structure') do |dir|
        path = File.join(dir, 'structure.sql')
        File.write(path, extension + comment)

        described_class.clean!(path)

        expect(File.read(path)).to eq(extension)
      end
    end
  end

  # Every structure dump goes through
  # ActiveRecord::Tasks::PostgreSQLDatabaseTasks#structure_dump.
  describe StructureDumpCleanup::AfterDump do
    let(:dumper) do
      Class.new do
        def initialize(text) = @text = text
        def structure_dump(filename, _extra_flags) = File.write(filename, @text)
      end
    end

    it 'cleans the file once pg_dump has written it' do
      Dir.mktmpdir('structure') do |dir|
        path = File.join(dir, 'structure.sql')
        dumper.prepend(described_class).new(extension + comment).structure_dump(path, nil)

        expect(File.read(path)).to eq(extension)
      end
    end

    it 'is prepended to the database tasks when the rake tasks load' do
      RakeTasks.ensure_loaded

      expect(ActiveRecord::Tasks::PostgreSQLDatabaseTasks.ancestors).to include(described_class)
    end
  end
end
