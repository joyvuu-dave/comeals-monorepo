# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/app_pages').to_s

# AppPages on its own: reading routes.json, and the rules it copies from
# React Router. spec/lib/app_pages_contract_spec.rb checks the rules
# against React Router itself; this file names the cases one by one, so
# a failure there has an example here to read.
RSpec.describe AppPages do
  # Patterns built in the example, not the ones built when the file
  # loaded, so a change to compile or part_source changes the answer.
  def page?(path)
    described_class.page?(path, patterns: described_class.patterns(described_class.load(described_class::FILE)))
  end

  describe '.page?' do
    it 'takes every example in routes.json' do
      described_class.pages.each do |name, page|
        page.fetch('examples').each do |example|
          expect(page?(example)).to be(true), "#{name}: #{example}"
        end
      end
    end

    it 'uses the patterns built when the file loads, when given none' do
      expect(described_class.page?('/reset-password')).to be(true)
      expect(described_class.page?('/foo')).to be(false)
    end

    {
      'the root, with any number of slashes' => ['/', '//', ''],
      'any case' => ['/CALENDAR/all/2026-11-01', '/Reset-Password', '/meals/1/EDIT/History'],
      'slashes at the end' => ['/calendar/all/2026-11-01/', '/confirm-email///'],
      'percent codes in a part' => ['/reset%2Dpassword', '/reset%2dpassword', '/meals/%31/edit', '/r%65set%2Dpassword'],
      'a %2F, which stays in its part' => ['/meals/1%2F2/edit', '/meals/1%2F2%2F3/edit'],
      'optional parts left out or filled in' => ['/calendar/all/2026-11-01/events', '/calendar/a/b/c/d/e'],
      'a part that does not decode, compared as sent' => ['/calendar/%/x', '/calendar/%zz/x', '/calendar/%C0/x']
    }.each do |what, paths|
      it "takes #{what}" do
        paths.each { |path| expect(page?(path)).to be(true), path }
      end
    end

    {
      'a part no page has' => ['/login', '/foo', '/.well-known/security.txt', '/foo.json'],
      'too few parts' => ['/calendar', '/calendar/all', '/meals/1'],
      'too many parts' => ['/calendar/a/b/c/d/e/f', '/meals/1/edit/history/x', '/reset-password/token'],
      'a wrong static part' => ['/meals/1/edit/x', '/meals/1/show'],
      'two slashes before the end' => ['//calendar/all/2026-11-01', '/calendar//all/2026-11-01', '/meals//edit'],
      'a decoded part that is not the static part' => ['/reset%2Fpassword', '/meals/1/edit%2Fhistory',
                                                       '/reset-pass%2Fword'],
      # React Router compares the whole path as sent when any part does
      # not decode, so the %73 in history stays as it is.
      'a path with a part that does not decode, though the rest would' => ['/meals/%/edit/hi%73tory',
                                                                           '/meals/%FF/edit/hi%73tory']
    }.each do |what, paths|
      it "refuses #{what}" do
        paths.each { |path| expect(page?(path)).to be(false), path }
      end
    end
  end

  describe '.load' do
    # Writes the JSON to a file and yields its path.
    def with_file(json)
      Tempfile.create(['routes', '.json']) do |file|
        file.write(json)
        file.flush
        yield file.path
      end
    end

    def pages_json(pages)
      JSON.generate('pages' => pages)
    end

    it 'gives the pages by name' do
      with_file(pages_json('home' => { 'path' => '/', 'examples' => ['/'] })) do |path|
        expect(described_class.load(path)).to eq('home' => { 'path' => '/', 'examples' => ['/'] })
      end
    end

    it 'refuses no file, naming the file and the error' do
      expect { described_class.load('/no/such/routes.json') }.to raise_error(
        AppPages::Invalid,
        "could not read the app's pages from /no/such/routes.json: " \
        'No such file or directory @ rb_sysopen - /no/such/routes.json'
      )
    end

    { 'a file that is not JSON' => '{', 'no pages key' => '{}' }.each do |what, json|
      it "refuses #{what}, naming the file and the error" do
        with_file(json) do |path|
          expect { described_class.load(path) }
            .to raise_error(AppPages::Invalid, /\Acould not read the app's pages from #{Regexp.escape(path)}: \S/)
        end
      end
    end

    { 'an empty list' => '{"pages": {}}', 'a list that is not an object' => '{"pages": []}',
      'a list of addresses' => '{"pages": ["/"]}' }.each do |what, json|
      it "refuses #{what}, naming the file" do
        with_file(json) do |path|
          expect { described_class.load(path) }.to raise_error(AppPages::Invalid, "#{path} lists no pages")
        end
      end
    end

    {
      'a page with no path' => { 'examples' => ['/'] },
      'a page whose path is not text' => { 'path' => 5, 'examples' => ['/'] }
    }.each do |what, page|
      it "refuses #{what}, as a page with no path" do
        with_file(pages_json('broken' => page)) do |path|
          expect { described_class.load(path) }
            .to raise_error(AppPages::Invalid, "the page broken in #{path} has no path")
        end
      end
    end

    {
      'a page with no example' => { 'path' => '/' },
      'a page with an empty list of examples' => { 'path' => '/', 'examples' => [] },
      'a page whose example is not a list' => { 'path' => '/', 'examples' => '/' }
    }.each do |what, page|
      it "refuses #{what}, as a page with no example" do
        with_file(pages_json('broken' => page)) do |path|
          expect { described_class.load(path) }
            .to raise_error(AppPages::Invalid, "the page broken in #{path} has no example")
        end
      end
    end

    {
      'a pattern that takes the rest of the path' => ['/meals/*', '"/meals/*" takes the rest of the path (*), ' \
                                                                  'which this list refuses'],
      'a pattern that does not start with /' => ['meals', '"meals" does not start with /'],
      'a part it cannot match' => ['/meals/{id}', '"/meals/{id}" has a part this list cannot match: "{id}"']
    }.each do |what, (pattern, message)|
      it "refuses #{what}, naming the pattern" do
        with_file(pages_json('broken' => { 'path' => pattern, 'examples' => ['/meals/1'] })) do |path|
          expect { described_class.load(path) }.to raise_error(AppPages::Invalid, message)
        end
      end
    end
  end

  describe '.compile' do
    it 'matches a static part as written, so a dot is a dot' do
      pattern = described_class.compile('/a.b')

      expect([pattern.match?('/a.b'), pattern.match?('/axb')]).to eq([true, false])
    end

    it 'matches any case, and a part at a time' do
      pattern = described_class.compile('/meals/:id/edit')

      expect(%w[/meals/1/edit /MEALS/1/Edit /meals/1/edit// /meals/1 /meals/1/2/edit].map { pattern.match?(it) })
        .to eq([true, true, true, false, false])
    end

    {
      'meals' => '"meals" does not start with /',
      '' => '"" does not start with /',
      '/meals/*' => '"/meals/*" takes the rest of the path (*), which this list refuses',
      '/*' => '"/*" takes the rest of the path (*), which this list refuses'
    }.each do |pattern, message|
      it "refuses #{pattern.inspect}, naming it" do
        expect { described_class.compile(pattern) }.to raise_error(AppPages::Invalid, message)
      end
    end
  end
end
