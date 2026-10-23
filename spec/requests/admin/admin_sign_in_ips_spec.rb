# frozen_string_literal: true

require 'rails_helper'

# Devise records the address each admin last signed in from
# (current_sign_in_ip, last_sign_in_ip). No admin page shows it, and no
# download may carry it, for a superuser either: an address says where a
# person was, and nobody needs it to run the community. Only AdminUser
# has these columns; the read-only token cannot open the admins pages at
# all (read_only_token_spec.rb).
RSpec.describe 'Admin sign-in addresses' do
  let(:community) { create(:community) }
  # Addresses from the ranges set aside for documentation (RFC 5737), so
  # no other value on a page can look like them.
  let(:current_ip) { '203.0.113.7' }
  let(:last_ip) { '198.51.100.9' }
  let!(:other_admin) do
    create(:admin_user, community: community, email: 'other@example.com').tap do |admin|
      admin.update_columns(current_sign_in_ip: current_ip, last_sign_in_ip: last_ip)
    end
  end

  before { host! 'admin.example.com' }

  def body_of(path)
    get path
    expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
    response.body
  end

  shared_examples 'an admin who sees no sign-in address' do
    it 'finds no address on any page or download of the admins' do
      paths = %W[/admin_users /admin_users.csv /admin_users.json
                 /admin_users/#{other_admin.id} /admin_users/#{other_admin.id}.json]
      bodies = paths.index_with { |path| body_of(path) }

      expect(bodies.select { |_, body| body.include?(current_ip) || body.include?(last_ip) }.keys).to eq([])
      # The pages are real ones, not refusals.
      expect(bodies.values).to all(include('other@example.com'))
    end

    it 'gets the admins CSV with no address column' do
      headers = body_of('/admin_users.csv').delete_prefix("\uFEFF").lines.first.chomp.split(',')

      expect(headers).to include('Email', 'Superuser')
      expect(headers & ['Current sign in ip', 'Last sign in ip']).to eq([])
    end

    # There is no XML download of any page (download_formats_spec.rb).
    it 'is refused the XML of the admins list and of an admin' do
      get '/admin_users.xml'
      expect(response).to have_http_status(:unauthorized)

      get "/admin_users/#{other_admin.id}.xml"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when signed in as a plain admin' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it_behaves_like 'an admin who sees no sign-in address'
  end

  context 'when signed in as a superuser' do
    before { sign_in create(:admin_user, community: community, superuser: true) }

    it_behaves_like 'an admin who sees no sign-in address'
  end
end
