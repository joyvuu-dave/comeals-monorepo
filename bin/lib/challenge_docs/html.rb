# frozen_string_literal: true

require 'erb'
require 'rdoc'

module ChallengeDocs
  # docs/challenges/challenges.html: one page that shows every challenge,
  # what is left to do, and what nobody has checked yet. It is written from
  # the challenge files by bin/challenges (index, reviewed and new all write
  # it), and the check fails when it does not match them, so it is never
  # out of date. It needs nothing from the internet: the styles and the
  # filter script are in the page.
  #
  # The page holds no date of its own (no "written at"), so writing it twice
  # from the same files gives the same bytes, and the check can compare.
  module Html
    FILE = 'challenges.html'
    OUT_OF_DATE = "#{FILE} does not match the challenge files; run bin/challenges index".freeze
    REMAINING = %w[exploring planned open].freeze
    FINISHED = %w[done declined].freeze
    STATUS_WORDS = {
      'open' => 'Not started', 'exploring' => 'Being explored', 'planned' => 'Planned',
      'done' => 'Done', 'declined' => 'Declined'
    }.freeze
    # A line in "Where we stand" that says something is not known yet.
    UNKNOWN = /\bnot (?:checked|found|tried|written|done|handled|measured)\b/i
    # An outside fact whose source nobody has read yet.
    UNREAD_SOURCE = /\(checked #{DATE}: Claude's memory/
    # The page's styles and its filter script, put into the page as text.
    STYLE = File.read(File.join(__dir__, 'page.css'))
    SCRIPT = File.read(File.join(__dir__, 'page.js'))

    module_function

    def h(text) = ERB::Util.html_escape(text.to_s)

    # The body of a challenge as HTML: Markdown through RDoc, with the
    # first heading left out (the card shows the title), each "## " heading
    # one level down, and links to other challenges pointed at their cards.
    # RDoc writes a link to "x.md" as "x_md.html" (it expects to have made
    # that page), so a link to another doc is turned back into the .md file.
    def body(doc)
      markdown = doc.body.sub(/\A\s*# .*\n/, '')
      html = RDoc::Markup::ToHtml.new.convert(RDoc::Markdown.parse(markdown))
      html.gsub(%r{<h2 id="[^"]*"><a href="[^"]*">(.*?)</a></h2>}, '<h3>\1</h3>')
          .gsub(/href="(\d{4})-[a-z0-9-]+_md\.html"/) { "href=\"#challenge-#{Regexp.last_match(1).to_i}\"" }
          .gsub(/href="([^"]+)_md\.html/, 'href="\1.md')
    end

    def chip(kind, value, label = value)
      "<span class=\"chip #{kind}-#{h(value)}\">#{h(label)}</span>"
    end

    def card(doc)
      front = doc.front
      watched = watched_files(doc)
      <<~HTML
        <details class="challenge" id="challenge-#{front['id']}" data-status="#{h(front['status'])}" data-area="#{h(front['area'])}">
          <summary><span class="num">#{front['id']}</span> <span class="title">#{h(front['title'])}</span> #{chip('status', front['status'], STATUS_WORDS[front['status']])} #{chip('area', front['area'])}#{Overview.badges(doc)}</summary>
          <div class="meta">Opened #{h(front['opened'])} · reviewed #{h(front['reviewed'])} · <code>docs/challenges/#{h(doc.name)}</code></div>
          #{watched}
          <div class="body">#{body(doc)}</div>
        </details>
      HTML
    end

    def watched_files(doc)
      count = doc.watches.size
      return '' if count.zero?

      items = doc.watches.map { |path| "<li><code>#{h(path)}</code></li>" }.join
      "<details class=\"watches\"><summary>Watches #{count} file#{'s' if count > 1}</summary>" \
        "<ul>#{items}</ul></details>"
    end

    def filters
      statuses = STATUSES.map { |status| "<button data-status=\"#{status}\">#{STATUS_WORDS[status]}</button>" }.join
      areas = AREAS.map { |area| "<button data-area=\"#{area}\">#{area}</button>" }.join
      <<~HTML
        <div class="filters">
          <input type="search" id="search" placeholder="Search the challenges" aria-label="Search the challenges">
          <div class="group" id="status-filter"><button data-status="" class="on">Every status</button>#{statuses}</div>
          <div class="group" id="area-filter"><button data-area="" class="on">Every area</button>#{areas}</div>
          <p id="shown"></p>
        </div>
      HTML
    end

    HEAD = <<~HTML.chomp
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Comeals challenges</title>
      <style>#{STYLE}</style>
      </head>
    HTML

    def render(docs)
      docs = docs.sort_by { |doc| doc.front['id'].to_i }
      <<~HTML
        #{HEAD}
        <body>
        <main>
        <header>
          <h1>Comeals challenges</h1>
          <p>Hard things someone could ask this app to handle, what would break, and where each one stands. Written by <code>bin/challenges</code> from the files in <code>docs/challenges/</code>. Do not edit this page; change the files and run <code>bin/challenges index</code>.</p>
        </header>
        <h2>Where things stand</h2>
        #{Overview.summary(docs)}
        <h2>By area</h2>
        #{Overview.areas(docs)}
        <h2>What is left</h2>
        #{Overview.remaining(docs)}
        <h2>Every challenge</h2>
        #{filters}
        <div id="list">
        #{docs.map { |doc| card(doc) }.join}
        </div>
        </main>
        <script>#{SCRIPT}</script>
        </body>
        </html>
      HTML
    end

    def problems(dir, docs)
      path = File.join(dir, FILE)
      File.exist?(path) && File.read(path) == render(docs) ? [] : [OUT_OF_DATE]
    end

    def write(dir)
      File.write(File.join(dir, FILE), render(ChallengeDocs.docs(dir).reject(&:error)))
    end
  end
end

require_relative 'overview'
