# typed: true
# frozen_string_literal: true

# Leave COMMENT ON EXTENSION out of db/structure.sql.
#
# pg_dump writes one for each extension. Only the extension's owner, or a
# superuser, may run one. On Heroku the extensions belong to rdsadmin, and
# the app's database user is neither. So on a new Heroku database, loading
# db/structure.sql stopped at the first one ("must be owner of extension
# pg_stat_statements") before it made any table. Without them the whole
# file loads; this was tested on a fresh Essential-0 database (PostgreSQL
# 18.4) on 2026-10-26 (#248).
#
# Not pg_dump's --no-comments: that would also leave out every comment on
# a table, a column or a function, which the file should keep.
#
# lib/tasks/structure_dump.rake runs this after every structure dump,
# so db:migrate, db:prepare and db:schema:dump all write the file
# without them. spec/db/structure_sql_spec.rb checks the committed file.
module StructureDumpCleanup
  extend T::Sig

  # The statement, with the three comment lines and the blank line pg_dump
  # writes above it when they are there, and the blank lines after it. The
  # text is one quoted string, where a quote is written as two.
  EXTENSION_COMMENT = /
    (?:^--\n--\ Name:\ EXTENSION\ [^\n]*;\ Type:\ COMMENT;[^\n]*\n--\n\n)?
    ^COMMENT\ ON\ EXTENSION\ [^\n]*?\ IS\ '(?:[^']|'')*';\n\n*
  /x

  sig { params(text: String).returns(String) }
  def self.without_extension_comments(text) = text.gsub(EXTENSION_COMMENT, '')

  sig { params(path: String).void }
  def self.clean!(path)
    text = File.read(path, encoding: 'UTF-8')
    cleaned = without_extension_comments(text)
    File.write(path, cleaned, encoding: 'UTF-8') unless cleaned == text
  end

  # Prepended to ActiveRecord::Tasks::PostgreSQLDatabaseTasks, which every
  # structure dump goes through.
  module AfterDump
    def structure_dump(filename, *)
      super
      StructureDumpCleanup.clean!(filename)
    end
  end
end
