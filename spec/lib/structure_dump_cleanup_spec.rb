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
    it 'rewrites the file without them' do
      Dir.mktmpdir('structure') do |dir|
        path = File.join(dir, 'structure.sql')
        File.write(path, extension + comment)

        described_class.clean!(path)

        expect(File.read(path)).to eq(extension)
      end
    end
  end
end
