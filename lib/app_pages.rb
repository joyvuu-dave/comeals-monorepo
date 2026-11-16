# typed: strict
# frozen_string_literal: true

require 'json'

# Which addresses are pages of the resident app. The server answers a
# page with the app (FallbackController#index, status 200) and every
# other address with the plain 404 page (FallbackController#not_found),
# so a program that asks for a file the app does not have, such as
# /.well-known/security.txt, is told it is not there (challenge 34,
# ADR 0016).
#
# The pages are the entries of app/frontend/src/routes.json, the same
# list the app draws its routes from (components/app/app_routes.tsx).
# This module matches a path the way React Router 8 does, so the two
# agree on every path; spec/lib/app_pages_contract_spec.rb asks React
# Router itself about thousands of paths and fails on any difference.
# What React Router does, and so what this does:
# - Upper and lower case are the same.
# - Any number of slashes may end the path. Two slashes anywhere else
#   match nothing.
# - Each part of the path is percent-decoded before it is compared, so
#   /reset%2Dpassword is /reset-password. A %2F stays inside its part.
#   If any part cannot be decoded, the whole path is compared as it was
#   sent.
# - A static part matches only itself; :name matches any one part; a ?
#   after either makes it optional.
#
# A pattern with a * is refused: it would make every address under it a
# page. The release phase loads this module (rake deploy:verify_app_pages),
# so a missing or broken routes.json fails the release, and the release
# before it keeps running.
module AppPages
  extend T::Sig

  class Invalid < StandardError; end

  FILE = T.let(File.expand_path('../app/frontend/src/routes.json', __dir__), String)

  # One part of a pattern: a static name, or :name; either may end in ?.
  PART = T.let(/\A(?<param>:)?(?<name>[A-Za-z0-9_.~-]+)(?<optional>\?)?\z/, Regexp)

  # patterns: the ones built when this file loads. A spec passes ones it
  # builds itself (AppPages.patterns), so that it tests compile as well.
  sig { params(path: String, patterns: T::Array[Regexp]).returns(T::Boolean) }
  def self.page?(path, patterns: PATTERNS)
    decoded = decode(path)
    patterns.any? { |pattern| pattern.match?(decoded) }
  end

  sig { params(pages: T::Hash[String, T::Hash[String, T.untyped]]).returns(T::Array[Regexp]) }
  def self.patterns(pages)
    pages.values.map { |page| compile(page.fetch('path')) }
  end

  # The pages, name -> { 'path' =>, 'examples' => [...] }, as routes.json
  # lists them. The deploy checks open every example.
  sig { returns(T::Hash[String, T::Hash[String, T.untyped]]) }
  def self.pages
    PAGES
  end

  sig { params(file: String).returns(T::Hash[String, T::Hash[String, T.untyped]]) }
  def self.load(file)
    pages = JSON.parse(File.read(file)).fetch('pages')
    raise Invalid, "#{file} lists no pages" unless pages.is_a?(Hash) && !pages.empty?

    pages.each do |name, page|
      path = page['path']
      raise Invalid, "the page #{name} in #{file} has no path" unless path.is_a?(String)
      raise Invalid, "the page #{name} in #{file} has no example" unless page['examples'].is_a?(Array) &&
                                                                         !page['examples'].empty?

      compile(path)
    end
    pages
  rescue JSON::ParserError, KeyError, Errno::ENOENT => e
    raise Invalid, "could not read the app's pages from #{file}: #{e.message}"
  end

  # A pattern as a regular expression over a decoded path, built the way
  # React Router's compilePath builds its own.
  sig { params(path: String).returns(Regexp) }
  def self.compile(path)
    raise Invalid, "#{path.inspect} does not start with /" unless path.start_with?('/')
    raise Invalid, "#{path.inspect} takes the rest of the path (*), which this list refuses" if path.include?('*')

    source = path.delete_prefix('/').split('/').map { |part| part_source(path, part) }.join
    Regexp.new("\\A#{source}/*\\z", Regexp::IGNORECASE)
  end

  sig { params(path: String, part: String).returns(String) }
  def self.part_source(path, part)
    match = PART.match(part)
    raise Invalid, "#{path.inspect} has a part this list cannot match: #{part.inspect}" if match.nil?

    one = match[:param] ? '/[^/]+' : "/#{Regexp.escape(T.must(match[:name]))}"
    match[:optional] ? "(?:#{one})?" : one
  end

  # React Router's decodePath: each part is decoded on its own, a decoded
  # slash goes back to %2F so it stays inside its part, and a path with a
  # part that does not decode is used as it was sent.
  sig { params(path: String).returns(String) }
  def self.decode(path)
    parts = path.split('/', -1).map { |part| decode_part(part) }
    parts.all? ? parts.join('/') : path
  end

  # decodeURIComponent, which fails on a % not followed by two hex digits
  # and on bytes that are not UTF-8. nil when it would fail.
  sig { params(part: String).returns(T.nilable(String)) }
  def self.decode_part(part)
    return nil if part.match?(/%(?!\h\h)/)

    decoded = part.gsub(/%\h\h/) { |code| T.must(code[1, 2]).hex.chr }.force_encoding(Encoding::UTF_8)
    return nil unless decoded.valid_encoding?

    decoded.gsub('/', '%2F')
  end

  PAGES = T.let(load(FILE).freeze, T::Hash[String, T::Hash[String, T.untyped]])
  PATTERNS = T.let(patterns(PAGES).freeze, T::Array[Regexp])
  private_class_method :part_source, :decode_part
end
