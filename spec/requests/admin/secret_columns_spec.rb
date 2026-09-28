# frozen_string_literal: true

require 'rails_helper'

# Every admin index page offers CSV, XML and JSON downloads, and every
# show page answers .json. No download may carry a column that holds a
# credential, or says when one was made. A resident's reset token is
# stored as it is mailed, and a live one is as good as the password. An
# admin who could read it could sign in as that resident, which
# app/admin/resident.rb rules out ("Send password reset email").
#
# The CSV columns come from ActiveAdmin's filter_attributes
# (config/initializers/active_admin.rb). The JSON comes from the model's
# serializable_hash: Resident's own, and Devise's for AdminUser. The XML
# download prints only "#<Resident:0x...>" for these pages (Rails 5 moved
# to_xml into a gem this app does not use), so it is checked only for
# carrying no secret. The read-only token's side is in
# read_only_token_spec.rb.
RSpec.describe 'Secret columns in admin downloads' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # No other column holds this date, and no id can look like it, so a
  # download that contains it got it from a secret column.
  let(:secret_time) { Time.zone.local(2001, 2, 3, 4, 5, 6) }
  let(:secret_date) { '2001-02-03' }
  let!(:ann) do
    create(:resident, community: community, unit: unit, name: 'Ann Adult', email: 'ann@example.com').tap do |resident|
      resident.update_columns(reset_password_token: 'live-reset-token', reset_password_sent_at: secret_time,
                              keys_valid_since: secret_time)
    end
  end
  # Another admin with a reset under way. Devise stores a digest of the
  # mailed token, not the token, but the digest is still not for export.
  let!(:other_admin) do
    create(:admin_user, community: community, email: 'other@example.com').tap do |admin|
      admin.update_columns(reset_password_token: 'admin-reset-digest', reset_password_sent_at: secret_time)
    end
  end

  before { host! 'admin.example.com' }

  def download(path)
    get path
    expect(response).to have_http_status(:ok), "#{path} answered #{response.status}"
    response.body
  end

  # The paths whose body contains any of the given strings.
  def paths_containing(secrets, paths)
    paths.index_with { |path| download(path) }
         .transform_values { |body| secrets.select { |secret| body.include?(secret) } }
         .reject { |_, found| found.empty? }
  end

  def csv_headers(path)
    download(path).delete_prefix("\uFEFF").lines.first.chomp.split(',')
  end

  shared_examples 'an admin who cannot download a secret' do
    it 'gets no resident secret from any download of the residents pages' do
      paths = %W[/residents.csv /residents.json /residents.xml /residents/#{ann.id}.json]

      expect(paths_containing(['live-reset-token', ann.password_digest, secret_date], paths)).to eq({})
    end

    it 'gets the residents CSV without the secret columns, and every other column' do
      expect(csv_headers('/residents.csv')).to eq(
        ['Id', 'Active', 'Birthday', 'Can cook', 'Created at', 'Email', 'Name', 'Updated at', 'Vegetarian', 'Phone',
         'Can reconcile']
      )
    end

    it 'gets the residents JSON without the secret keys, on the index and the show page' do
      shown = %w[id active birthday can_cook can_reconcile community_id created_at email kind name phone unit_id
                 updated_at vegetarian]

      expect(JSON.parse(download('/residents.json')).map(&:keys)).to match([match_array(shown)])
      expect(JSON.parse(download("/residents/#{ann.id}.json")).keys).to match_array(shown)
    end

    it 'gets no admin secret from any download of the admins pages' do
      paths = %W[/admin_users.csv /admin_users.json /admin_users.xml /admin_users/#{other_admin.id}.json]
      secrets = ['admin-reset-digest', other_admin.encrypted_password, secret_date]

      expect(paths_containing(secrets, paths)).to eq({})
    end

    it 'gets the admins CSV without the password or reset columns' do
      headers = csv_headers('/admin_users.csv')

      expect(headers).to include('Email', 'Superuser')
      expect(headers & ['Encrypted password', 'Reset password token', 'Reset password sent at']).to eq([])
    end

    # Devise leaves its own columns out of serializable_hash.
    it 'gets the admins JSON with only the columns Devise lets through' do
      shown = %w[id community_id created_at email phone superuser updated_at]

      # Two rows: other_admin and the admin signed in.
      expect(JSON.parse(download('/admin_users.json')).map(&:keys)).to match([match_array(shown)] * 2)
      expect(JSON.parse(download("/admin_users/#{other_admin.id}.json")).keys).to match_array(shown)
    end
  end

  context 'when signed in as a plain admin' do
    before { sign_in create(:admin_user, community: community, superuser: false) }

    it_behaves_like 'an admin who cannot download a secret'

    # The case app/admin/resident.rb rules out: send the reset, then read
    # the link. The token here is the one PasswordReset made and mailed.
    it 'cannot read the reset link it just had mailed' do
      post "/residents/#{ann.id}/send_password_reset"
      mailed_token = ann.reload.reset_password_token
      expect(mailed_token).to be_present
      expect(mailed_token).not_to eq('live-reset-token')
      expect(ActionMailer::Base.deliveries.last.body.encoded).to include(mailed_token)

      paths = %W[/residents.csv /residents.json /residents.xml /residents/#{ann.id}.json]

      expect(paths_containing([mailed_token], paths)).to eq({})
    end
  end

  context 'when signed in as a superuser' do
    before { sign_in create(:admin_user, community: community, superuser: true) }

    it_behaves_like 'an admin who cannot download a secret'
  end

  # The checks above name today's columns. These find the next one: any
  # column whose name says it holds a password, a digest, a token or a
  # secret, in any table.
  describe 'every credential column in the database' do
    def credential_columns
      connection = ActiveRecord::Base.connection
      connection.tables.flat_map do |table|
        connection.columns(table).map(&:name).grep(/password|digest|token|secret/).map { |column| [table, column] }
      end
    end

    it 'is found, so the checks below cannot pass on an empty list' do
      expect(credential_columns).to include(
        %w[residents password_digest], %w[residents reset_password_token],
        %w[admin_users encrypted_password], %w[admin_users reset_password_token], %w[keys token]
      )
    end

    it 'is left out of every CSV download and default admin page' do
      filtered = ActiveAdmin.application.filter_attributes.map(&:to_s)

      expect(credential_columns.map(&:last).uniq - filtered).to eq([])
    end

    # ActiveAdmin also registers its own Comment model, whose table this
    # app never made (config.comments = false), so only the app's models
    # are checked.
    it 'is left out of the JSON of every model that has an admin page' do
      ActiveAdmin.application.load!
      models = ActiveAdmin.application.namespaces[:admin].resources.grep(ActiveAdmin::Resource)
                          .map(&:resource_class).select { |model| model < ApplicationRecord }
      by_table = credential_columns.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

      leaked = models.filter_map do |model|
        columns = model.new.serializable_hash.keys & by_table.fetch(model.table_name, [])
        "#{model.name}: #{columns.join(', ')}" if columns.any?
      end

      expect(models.map(&:name)).to include('AdminUser', 'Resident')
      expect(leaked).to eq([])
    end
  end
end
