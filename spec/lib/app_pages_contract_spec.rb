# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/app_pages').to_s
require 'open3'

# The server and the app must agree on every path: a path the app shows
# a page for gets 200 from the server, and a path it shows Page not found
# for gets 404 (ADR 0016). The server matches with its own copy of React
# Router's rules (AppPages). This spec gives the same paths to both and
# fails on any difference. React Router answers through
# spec/support/app_pages_oracle.mjs, so nothing here repeats its rules,
# and adding a page to routes.json needs no change here.
RSpec.describe AppPages do
  describe '.page?, compared with React Router' do
    def react_router_pages(paths)
      oracle = Rails.root.join('spec/support/app_pages_oracle.mjs').to_s
      out, err, status = Open3.capture3('node', oracle, stdin_data: JSON.generate(paths))
      raise "#{oracle} failed: #{err}" unless status.success?

      JSON.parse(out)
    end

    def expect_agreement(paths)
      react_router = react_router_pages(paths)
      # Built here, so a change to compile changes the answer.
      patterns = described_class.patterns(described_class.load(AppPages::FILE))
      differences = paths.zip(react_router).filter_map do |path, theirs|
        ours = described_class.page?(path, patterns:)
        if ours != theirs
          "#{path.inspect}: React Router #{theirs ? 'page' : 'not a page'}, AppPages #{ours ? 'page' : 'not a page'}"
        end
      end

      expect(differences).to eq([])
    end

    # The parts the patterns use, in other cases and codes, and parts no
    # page has, put together in every order. A fixed seed, so a failure
    # shows the same paths again.
    def random_paths(count, seed:)
      parts = AppPages.pages.values.flat_map { |page| page.fetch('path').split('/') }
                      .map { |part| part.delete_prefix(':').delete_suffix('?') }.reject(&:empty?).uniq
      parts += parts.map(&:upcase)
      parts += %w[all 2026-11-01 1 42 %31 1%2F2 %2D reset%2Dpassword confirm%2Demail % %zz %C0 %E2%82%AC
                  . .. x.json .well-known security.txt login foo a]
      random = Random.new(seed)
      Array.new(count) do
        body = Array.new(random.rand(0..7)) { parts.sample(random: random) }.join('/')
        ['/', '//', ''].sample(random: random) + body + ['', '/', '//'].sample(random: random)
      end
    end

    it 'on every example in routes.json, and on each one changed a little' do
      examples = described_class.pages.values.flat_map { |page| page.fetch('examples') }
      changed = examples.flat_map do |example|
        [example.upcase, "#{example}/", "#{example}//", "/#{example}", "#{example}/x", example.sub(%r{/[^/]*\z}, '')]
      end

      expect_agreement(examples + changed)
    end

    it 'on 5,000 paths made from the parts of the patterns' do
      expect_agreement(random_paths(5_000, seed: 34))
    end
  end
end
