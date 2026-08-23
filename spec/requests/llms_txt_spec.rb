# frozen_string_literal: true

require 'rails_helper'

# public/llms.txt and public/api.md describe the API for people writing
# scripts and agents against it. The files are static, so nothing ties
# them to the code. These specs are that tie: the files must be served,
# and every /api/v1 route must appear in the reference.
RSpec.describe 'llms.txt and the API reference' do
  let(:reference) { Rails.public_path.join('api.md').read }

  it 'serves /llms.txt as plain text' do
    get '/llms.txt'
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('text/plain')
    expect(response.body).to include('# Comeals')
  end

  it 'serves /api.md as markdown' do
    get '/api.md'
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with('text/markdown')
    expect(response.body).to include('# Comeals API')
  end

  it 'links to the API reference from llms.txt' do
    expect(Rails.public_path.join('llms.txt').read).to include('https://comeals.com/api.md')
  end

  it 'documents every /api/v1 route' do
    routes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix('(.:format)')
      next unless path.start_with?('/api/v1/')

      verb = route.verb
      next if verb.blank?

      [verb, path.delete_prefix('/api/v1')]
    end

    missing = routes.reject do |verb, path|
      # The doc writes a path as `/meals/:meal_id/cooks`, the same way
      # routes.rb does. The verb is either in the table cell before it
      # (Prettier pads the cells, so allow any spacing) or on the same
      # line of a code block.
      escaped = Regexp.escape(path)
      reference.match?(/\|\s*`#{verb}`\s*\|\s*`#{escaped}[?`]/) ||
        reference.match?(/^#{verb} #{escaped}$/)
    end

    expect(missing).to be_empty, "api.md does not mention: #{missing.map { |v, p| "#{v} #{p}" }.join(', ')}"
  end

  it 'documents no route that does not exist' do
    routes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix('(.:format)')
      next unless path.start_with?('/api/v1/')

      [route.verb, path.delete_prefix('/api/v1')]
    end

    # Every table row or code-block line that names a verb and a path.
    documented = reference.scan(/\|\s*`(GET|POST|PATCH|DELETE)`\s*\|\s*`([^`?]+)/) +
                 reference.scan(/^(GET|POST|PATCH|DELETE) (\S+)$/)

    stale = documented.uniq.reject { |verb, path| routes.include?([verb, path]) }

    expect(stale).to be_empty, "api.md names routes that do not exist: #{stale.map { |v, p| "#{v} #{p}" }.join(', ')}"
  end
end
