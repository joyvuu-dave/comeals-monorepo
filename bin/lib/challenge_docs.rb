# frozen_string_literal: true

require 'date'
require 'digest'
require 'yaml'

# The rules for docs/challenges/, as code. docs/challenges/README.md says
# the same rules in words; spec/bin/challenge_docs_spec.rb runs them on the
# real folder, so bin/check and CI fail when a challenge doc breaks one.
# bin/challenges is the command line for people and agents.
#
# The parts: this file reads the docs and lists every problem;
# challenge_docs/checks.rb holds the rules for one doc and for the set;
# challenge_docs/index.rb writes the index in the README;
# challenge_docs/watches.rb keeps the fingerprints of watched files;
# challenge_docs/cli.rb is the command line.
module ChallengeDocs
  AREAS = %w[security concurrency portability time money people operations proof quality].freeze
  STATUSES = %w[open exploring planned done declined].freeze
  # A doc with one of these statuses says what was decided, in "Decision".
  DECIDED = %w[planned done declined].freeze
  KEYS = %w[id title area status opened reviewed watches].freeze
  SECTIONS = ['The challenge', 'The case that breaks it', 'Where we stand', 'Options',
              'Outside facts', 'Decision', 'History'].freeze
  REQUIRED_SECTIONS = ['The challenge', 'The case that breaks it', 'Where we stand', 'Options', 'History'].freeze
  # Words that stop being true with no change to the text. A doc names the
  # date instead ("as of 2026-11-07"); its reviewed date is when "today" was.
  # The last four are the project's plain-language rules (AGENTS.md).
  BANNED_WORDS = %w[currently recently soon nowadays matter matters quietly silently].freeze
  # An outside fact (about other software, a company, a law) that nobody
  # has checked for this many days fails the check.
  OUTSIDE_FACT_DAYS = 365
  FILE_NAME = /\A(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md\z/
  DATE = /\d{4}-\d{2}-\d{2}/
  HISTORY_LINE = /\A- (#{DATE}): \S/
  OUTSIDE_FACT = /\(checked (#{DATE}): [^)]+\)/

  Doc = Struct.new(:path, :front, :body, :error) do
    def name = File.basename(path)

    # Each "## " heading, in order, with the text under it.
    def sections
      body.split(/^## /).drop(1).to_h do |part|
        heading, text = part.split("\n", 2)
        [heading.strip, text.to_s.strip]
      end
    end

    def watches = Array(front['watches']).grep(String)
  end

  module_function

  def docs(dir)
    Dir.glob(File.join(dir, '*.md')).reject { |path| File.basename(path) == 'README.md' }.map { |path| read(path) }
  end

  def read(path)
    text = File.read(path)
    match = text.match(/\A---\n(.*?)\n---\n(.*)\z/m)
    return Doc.new(path, nil, text, 'has no front matter between two --- lines at the top') unless match

    front = YAML.safe_load(match[1], permitted_classes: [Date])
    return Doc.new(path, nil, text, 'has front matter that is not a list of keys') unless front.is_a?(Hash)

    Doc.new(path, front, match[2], nil)
  rescue Psych::SyntaxError => e
    Doc.new(path, nil, text, "has front matter that is not YAML (#{e.message})")
  end

  # Every rule broken in dir, as sentences. root is the repo, for the paths.
  def problems(dir, root:, today:)
    all = docs(dir)
    good = all.reject(&:error)
    all.flat_map { |doc| Checks.doc(doc, root, today) } +
      Checks.ids(good) + Index.problems(dir, good) + Watches.problems(dir, good, root)
  end
end

require_relative 'challenge_docs/checks'
require_relative 'challenge_docs/index'
require_relative 'challenge_docs/watches'
require_relative 'challenge_docs/cli'
