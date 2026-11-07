# frozen_string_literal: true

module ChallengeDocs
  # The index table in docs/challenges/README.md, written from the front
  # matter of every challenge, between two comment lines.
  module Index
    START = '<!-- The index below is written by bin/challenges index. Do not edit it by hand. -->'
    FINISH = '<!-- End of the index. -->'
    NO_MARKERS = 'README.md has no index markers; put back the two comment lines around the index'
    OUT_OF_DATE = 'README.md has an index that does not match the challenge files; run bin/challenges index'

    module_function

    # The table the way Prettier writes it (bin/check runs Prettier on
    # every Markdown file): each column as wide as its widest cell, and at
    # least 3, with the cells padded by spaces. Prettier counts a wide
    # character (Chinese, an emoji) as two columns and this counts it as one,
    # so a title with one would fail Prettier's check; keep titles in plain
    # letters.
    def table(docs)
      rows = docs.sort_by { |doc| doc.front['id'].to_i }.map do |doc|
        front = doc.front
        [front['id'], "[#{front['title']}](#{doc.name})", front['area'], front['status'], front['reviewed']].map(&:to_s)
      end
      header = ['#', 'Challenge', 'Area', 'Status', 'Reviewed']
      widths = header.each_index.map { |column| [3, *([header] + rows).map { |row| row[column].length }].max }
      line = ->(cells) { "| #{cells.each_with_index.map { |cell, column| cell.ljust(widths[column]) }.join(' | ')} |" }
      [line.call(header), line.call(widths.map { |width| '-' * width }), *rows.map(&line)].join("\n")
    end

    # The README with its index written again, or nil when the markers are gone.
    def readme_with_index(readme, docs)
      before, rest = readme.split(START, 2)
      return nil unless rest&.include?(FINISH)

      "#{before}#{START}\n\n#{table(docs)}\n\n#{FINISH}#{rest.split(FINISH, 2).last}"
    end

    def problems(dir, docs)
      readme = File.read(File.join(dir, 'README.md'))
      expected = readme_with_index(readme, docs)
      return [NO_MARKERS] unless expected

      expected == readme ? [] : [OUT_OF_DATE]
    end

    # Writes the index. Returns nil, or the problem that stopped it.
    def write(dir)
      path = File.join(dir, 'README.md')
      text = readme_with_index(File.read(path), ChallengeDocs.docs(dir).reject(&:error))
      return NO_MARKERS unless text

      File.write(path, text)
      nil
    end
  end
end
