# frozen_string_literal: true

module ChallengeDocs
  # The rules for one challenge doc, and for the set of them.
  module Checks
    # A repo path in backticks: one of the top folders, or a root Markdown
    # file. A path with * or < > in it is a pattern, not a file, and is left
    # alone. A :line or #anchor at the end is cut off before the check.
    PATH = %r{`((?:app|bin|config|db|docs|lib|public|spec|tests|\.agents|\.github)/[^`\s*<>]+|[A-Z][A-Z_]*\.md)`}
    LINK = /\]\(([^)\s]+)\)/
    WEB_LINK = %r{\A(?:https?://|mailto:|#)}

    module_function

    def doc(doc, root, today)
      return ["#{doc.name} #{doc.error}"] if doc.error

      name_problems(doc) + value_problems(doc) + date_problems(doc) + section_problems(doc) +
        text_problems(doc, root, today)
    end

    def name_problems(doc)
      front = doc.front
      found = []
      missing = KEYS - front.keys
      extra = front.keys - KEYS
      found << "#{doc.name} is missing #{missing.join(', ')} in its front matter" if missing.any?
      found << "#{doc.name} has #{extra.join(', ')} in its front matter, which is not a known key" if extra.any?
      number = doc.name[FILE_NAME, 1]
      return found << "#{doc.name} must be named like 0012-short-name.md" unless number
      return found if front['id'] == number.to_i

      found << "#{doc.name} has id #{front['id'].inspect}, but its file name says #{number.to_i}"
    end

    def value_problems(doc)
      front = doc.front
      found = []
      unless AREAS.include?(front['area'])
        found << "#{doc.name} has area #{front['area'].inspect}; use one of #{AREAS.join(', ')}"
      end
      unless STATUSES.include?(front['status'])
        found << "#{doc.name} has status #{front['status'].inspect}; use one of #{STATUSES.join(', ')}"
      end
      return found if front['watches'].is_a?(Array) && front['watches'].all?(String)

      found << "#{doc.name} must list its watched files under watches (an empty list is [])"
    end

    def date_problems(doc)
      opened, reviewed = doc.front.values_at('opened', 'reviewed')
      found = %w[opened reviewed].reject { |key| doc.front[key].is_a?(Date) }.map do |key|
        "#{doc.name} must give #{key} as a date like 2026-11-07"
      end
      found << "#{doc.name} was reviewed before it was opened" if found.empty? && reviewed < opened
      found
    end

    def section_problems(doc)
      sections = doc.sections
      names = sections.keys
      found = []
      title = doc.front['title']
      unless doc.body.lstrip.start_with?("# #{title}\n")
        found << "#{doc.name} must start with the heading \"# #{title}\""
      end
      found.concat((names - SECTIONS).map do |name|
        "#{doc.name} has a section \"#{name}\"; the sections are #{SECTIONS.join(', ')}"
      end)
      found.concat((REQUIRED_SECTIONS - names).map { |name| "#{doc.name} has no \"#{name}\" section" })
      if names != SECTIONS.select { |name| names.include?(name) }
        found << "#{doc.name} has its sections out of order; the order is #{SECTIONS.join(', ')}"
      end
      found + decision_problems(doc, sections) + history_problems(doc, sections['History'].to_s) +
        outside_fact_problems(doc, sections['Outside facts'].to_s)
    end

    def decision_problems(doc, sections)
      status = doc.front['status']
      return [] unless DECIDED.include?(status) && sections['Decision'].to_s.empty?

      ["#{doc.name} is #{status}, so it needs a \"Decision\" section that says what was decided"]
    end

    def history_problems(doc, history)
      lines = history.lines.map(&:chomp).reject(&:empty?)
      found = lines.grep_v(HISTORY_LINE).map do |line|
        "#{doc.name} has a History line that does not start with \"- YYYY-MM-DD: \": #{line}"
      end
      return found if lines.first.to_s[HISTORY_LINE, 1] == doc.front['opened'].to_s

      found << "#{doc.name} must start its History with the day it was opened, #{doc.front['opened']}"
    end

    def outside_fact_problems(doc, facts)
      facts.lines.map(&:chomp).select { |line| line.start_with?('- ') }.grep_v(OUTSIDE_FACT).map do |line|
        "#{doc.name} has an outside fact with no \"(checked YYYY-MM-DD: source)\": #{line}"
      end
    end

    def text_problems(doc, root, today)
      text = doc.body
      found = BANNED_WORDS.select { |word| text.match?(/\b#{word}\b/i) }.map do |word|
        "#{doc.name} uses the word \"#{word}\"; write the date or the plain fact instead"
      end
      found.concat(missing_paths(text, root).map { |path| "#{doc.name} names #{path}, which does not exist" })
      found.concat(broken_links(doc).map { |link| "#{doc.name} links to #{link}, which does not exist" })
      found.concat(old_facts(doc, today).map do |date|
        "#{doc.name} has an outside fact last checked #{date}; check it again and change the date"
      end)
    end

    def missing_paths(text, root)
      text.scan(PATH).flatten.map { |path| path.sub(/[:#].*\z/, '') }.uniq.reject do |path|
        File.exist?(File.join(root, path))
      end
    end

    def broken_links(doc)
      doc.body.scan(LINK).flatten.grep_v(WEB_LINK).reject do |link|
        File.exist?(File.expand_path(link.sub(/#.*\z/, ''), File.dirname(doc.path)))
      end
    end

    def old_facts(doc, today)
      doc.sections['Outside facts'].to_s.scan(OUTSIDE_FACT).flatten.uniq.select do |date|
        (today - Date.iso8601(date)).to_i > OUTSIDE_FACT_DAYS
      end
    end

    def ids(docs)
      ids = docs.map { |doc| doc.front['id'] }.grep(Integer).sort
      found = ids.tally.select { |_, count| count > 1 }.keys.map { |id| "More than one challenge has id #{id}" }
      return found if ids == (1..ids.size).to_a

      found << "The challenge ids must run 1, 2, 3 ... with no gap; they are #{ids.join(', ')}"
    end
  end
end
