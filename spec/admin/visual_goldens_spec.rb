# frozen_string_literal: true

require 'rails_helper'

# Every admin page has a golden image (tests/admin/visual.spec.js), the
# way every line of Ruby has a spec. The pages are listed here from the
# routes, not copied from the visual spec, so a new admin resource or
# action fails this spec until its goldens exist. A GET route that is not
# a page of its own is in not_a_page with the reason. The Vitest side of
# this is tests/unit/screens.test.js.
RSpec.describe 'admin visual goldens' do
  let(:goldens_dir) { Rails.root.join('tests/admin/visual.spec.js-snapshots') }
  let(:platforms) { %w[darwin linux] }

  let(:not_a_page) do
    {
      'admin/communities#index' => 'redirects to the one community\'s page',
      'admin/communities#new' => 'refused once the community exists (SuperuserAdapter), and it always does',
      'admin/comments#index' => 'comments are off; the route ahead of ActiveAdmin\'s answers 404 (#82)',
      'admin/comments#show' => 'comments are off; the route ahead of ActiveAdmin\'s answers 404 (#82)'
    }
  end

  # Devise pages carry no resource name; they are named by their path.
  let(:devise_names) do
    {
      'active_admin/devise/sessions#new' => 'login',
      'active_admin/devise/passwords#new' => 'password-new',
      'active_admin/devise/passwords#edit' => 'password-edit'
    }
  end

  # Every GET route on the admin host, as controller#action. The dashboard
  # answers at / and at /dashboard; that is one page.
  let(:admin_routes) do
    Rails.application.routes.routes.filter_map do |route|
      next unless route.verb == 'GET'

      controller = route.requirements[:controller]
      action = route.requirements[:action]
      next unless controller&.start_with?('admin/', 'active_admin/')

      "#{controller}##{action}"
    end.uniq
  end

  # Playwright writes a golden's file name with every underscore turned
  # into a hyphen, so admin/admin_users#index is admin-users-index.
  let(:golden_names) do
    (admin_routes - not_a_page.keys).map do |page|
      devise_names.fetch(page) do
        controller, action = page.split('#')
        "#{controller.delete_prefix('admin/').tr('_', '-')}-#{action}"
      end
    end
  end

  it 'has a golden for every admin page on every platform' do
    missing = golden_names.flat_map do |name|
      platforms.filter_map do |platform|
        file = "#{name}-admin-#{platform}.png"
        file unless goldens_dir.join(file).exist?
      end
    end
    expect(missing).to eq([]),
                       "record goldens for #{missing.join(', ')} (see tests/admin/visual.spec.js)"
  end

  it 'has no golden for a page that no longer exists' do
    recorded = goldens_dir.glob('*.png').map { |png| png.basename.to_s.sub(/-admin-[a-z]+\.png\z/, '') }.uniq
    expect(recorded - golden_names).to eq([])
  end

  it 'explains away only routes that exist' do
    expect(not_a_page.keys - admin_routes).to eq([])
  end
end
