# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/app_pages').to_s

# AppPages on its own: reading routes.json, and the rules it copies from
# React Router. spec/lib/app_pages_contract_spec.rb checks the rules
# against React Router itself; this file names the cases one by one, so
# a failure there has an example here to read.
RSpec.describe AppPages do
  describe '.page?' do
    it 'takes every example in routes.json' do
      described_class.pages.each do |name, page|
        page.fetch('examples').each do |example|
          expect(described_class.page?(example)).to be(true), "#{name}: #{example}"
        end
      end
    end

    {
      'the root, with any number of slashes' => ['/', '//', ''],
      'any case' => ['/CALENDAR/all/2026-11-01', '/Reset-Password', '/meals/1/EDIT/History'],
      'slashes at the end' => ['/calendar/all/2026-11-01/', '/confirm-email///'],
      'percent codes in a part' => ['/reset%2Dpassword', '/reset%2dpassword', '/meals/%31/edit'],
      'a %2F, which stays in its part' => ['/meals/1%2F2/edit'],
      'optional parts left out or filled in' => ['/calendar/all/2026-11-01/events', '/calendar/a/b/c/d/e'],
      'a part that does not decode, compared as sent' => ['/calendar/%/x', '/calendar/%zz/x', '/calendar/%C0/x']
    }.each do |what, paths|
      it "takes #{what}" do
        paths.each { |path| expect(described_class.page?(path)).to be(true), path }
      end
    end

    {
      'a part no page has' => ['/login', '/foo', '/.well-known/security.txt', '/foo.json'],
      'too few parts' => ['/calendar', '/calendar/all', '/meals/1'],
      'too many parts' => ['/calendar/a/b/c/d/e/f', '/meals/1/edit/history/x', '/reset-password/token'],
      'a wrong static part' => ['/meals/1/edit/x', '/meals/1/show'],
      'two slashes before the end' => ['//calendar/all/2026-11-01', '/calendar//all/2026-11-01', '/meals//edit'],
      'a decoded part that is not the static part' => ['/reset%2Fpassword', '/meals/1/edit%2Fhistory']
    }.each do |what, paths|
      it "refuses #{what}" do
        paths.each { |path| expect(described_class.page?(path)).to be(false), path }
      end
    end
  end

  describe '.load' do
    def load_json(json)
      Tempfile.create(['routes', '.json']) do |file|
        file.write(json)
        file.flush
        described_class.load(file.path)
      end
    end

    def pages_json(pages)
      JSON.generate('pages' => pages)
    end

    it 'gives the pages by name' do
      pages = load_json(pages_json('home' => { 'path' => '/', 'examples' => ['/'] }))

      expect(pages).to eq('home' => { 'path' => '/', 'examples' => ['/'] })
    end

    {
      'no file' => [nil, /could not read the app's pages/],
      'a file that is not JSON' => ['{', /could not read the app's pages/],
      'no pages key' => ['{}', /could not read the app's pages/],
      'an empty list' => ['{"pages": {}}', /lists no pages/],
      'a list that is not an object' => ['{"pages": []}', /lists no pages/]
    }.each do |what, (json, message)|
      it "refuses #{what}" do
        if json.nil?
          expect { described_class.load('/no/such/routes.json') }.to raise_error(AppPages::Invalid, message)
        else
          expect { load_json(json) }.to raise_error(AppPages::Invalid, message)
        end
      end
    end

    {
      'a page with no path' => [{ 'examples' => ['/'] }, /has no path/],
      'a page with no example' => [{ 'path' => '/' }, /has no example/],
      'a page with an empty list of examples' => [{ 'path' => '/', 'examples' => [] }, /has no example/],
      'a pattern that takes the rest of the path' => [{ 'path' => '/meals/*', 'examples' => ['/meals/1'] },
                                                      /takes the rest of the path/],
      'a pattern that does not start with /' => [{ 'path' => 'meals', 'examples' => ['/meals'] },
                                                 /does not start with/],
      'a part it cannot match' => [{ 'path' => '/meals/{id}', 'examples' => ['/meals/1'] }, /cannot match/]
    }.each do |what, (page, message)|
      it "refuses #{what}, naming it" do
        expect { load_json(pages_json('broken' => page)) }.to raise_error(AppPages::Invalid, message)
      end
    end
  end
end
