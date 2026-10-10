# frozen_string_literal: true

require 'rails_helper'
require 'csv'

# An admin index is sorted by ?order=<key>_<asc|desc>. The key must be a
# column the model lists as sortable (ransortable_attributes, which is
# ransackable_attributes unless a model says otherwise), or a key the page
# declares with order_by. Any other key is refused, and the page keeps its
# default order. The order of the rows says something about the values in
# the sort column, so a column that no page shows must not be sortable
# either. The rule is in lib/admin_order_clause.rb. Every sort link the
# index pages draw is followed in all_pages_spec.rb.
RSpec.describe 'Admin index sort order' do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:token) { 'test-readonly-token' }

  # Created out of name order. Each secret column's values are in a third
  # order, so a sort by a secret, the default name order, the id order and
  # no order at all each list the three differently, in both directions.
  let!(:cara) { resident_with_secrets('Cara Cole', 2) }
  let!(:ann) { resident_with_secrets('Ann Adams', 3) }
  let!(:bob) { resident_with_secrets('Bob Brown', 1) }
  let(:name_order) { [ann, bob, cara].map(&:id) }

  let(:resident_secrets) { %w[password_digest reset_password_token reset_password_sent_at keys_valid_since] }

  def resident_with_secrets(name, rank)
    create(:resident, community: community, unit: unit, name: name).tap do |resident|
      time = Time.zone.local(2001, 2, rank)
      resident.update_columns(password_digest: "digest-#{rank}", reset_password_token: "token-#{rank}",
                              reset_password_sent_at: time, keys_valid_since: time)
    end
  end

  before { host! 'admin.example.com' }

  # One bill for each resident. meals.date_desc, the bills page's default,
  # lists Ann's, then Bob's, then Cara's. The bills are made in another
  # order, so their ids are not in that order.
  def bill_ids_by_date
    [[cara, 3], [ann, 1], [bob, 2]].each do |cook, days_ago|
      create(:bill, community: community, resident: cook, amount: BigDecimal('10'),
                    meal: create(:meal, community: community, date: Date.new(2026, 9, 10) - days_ago))
    end
    [ann, bob, cara].map { |cook| cook.bills.sole.id }
  end

  # The ids of the rows the index lists, in the order it lists them, and
  # every SQL statement the request ran.
  def fetch(path, format, order, extra = {})
    statements = []
    record = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
      get(format == 'html' ? path : "#{path}.#{format}", params: { order: order }.compact.merge(viewer_params, extra))
    end
    expect(response).to have_http_status(:ok), "#{path}.#{format}?order=#{order} answered #{response.status}"
    [listed_ids(response.body, format), statements]
  end

  def listed_ids(body, format)
    case format
    when 'html'
      Nokogiri::HTML(body).css('table.index_table > tbody > tr').map { |row| row['id'][/\d+\z/].to_i }
    when 'csv'
      CSV.parse(body.delete_prefix("\uFEFF"), headers: true).map { |row| row['Id'].to_i }
    when 'json'
      JSON.parse(body).pluck('id')
    end
  end

  # The part of each statement after its last ORDER BY, which is where a
  # sort key would reach the SQL. The SELECT list of an eager_load names
  # every column, secret ones too, and is not a sort.
  def order_by_parts(statements)
    statements.filter_map { |sql| sql.split(/ORDER BY/i).drop(1).last }
  end

  # The same checks for every viewer and every format: the rows come in
  # the page's default order, and no ORDER BY names the column.
  def expect_default_order(path, order, default_ids, column, extra = {})
    %w[html csv json].each do |format|
      ids, statements = fetch(path, format, order, extra)

      expect(ids).to eq(default_ids), "#{path}.#{format}?order=#{order} listed #{ids}, not the default #{default_ids}"
      expect(order_by_parts(statements).grep(/#{column}/)).to eq([]), "#{path}.#{format}?order=#{order} sorted by it"
    end
  end

  shared_examples 'a viewer who cannot sort by a secret column' do
    it 'gets the residents in name order when it asks for a secret column, in each direction' do
      resident_secrets.product(%w[asc desc]).each do |column, direction|
        expect_default_order('/residents', "#{column}_#{direction}", name_order, column)
      end
    end

    # The bills page joins each bill's cook, so a key naming a column of
    # the residents table would sort bills by their cooks' secrets. Ransack
    # may reach the cook too (Bill names resident as searchable), so its
    # sort is tried the same way.
    it 'gets the bills in their default order when it asks for a cook\'s secret column' do
      default_ids = bill_ids_by_date

      resident_secrets.each do |column|
        expect_default_order('/bills', "residents.#{column}_asc", default_ids, column)
        expect_default_order('/bills', nil, default_ids, column, { q: { s: "resident_#{column} asc" } })
      end
    end

    it 'gets the residents in name order when it asks for a column of a table the page does not join' do
      expect_default_order('/residents', 'admin_users.encrypted_password_asc', name_order, 'encrypted_password')
    end

    # ActiveAdmin's key grammar allows a JSON operator after the column.
    # No column here is JSON, so the operator could only make the SQL fail.
    it 'gets the residents in name order when the key carries an operator' do
      expect_default_order('/residents', "name->'x'_desc", name_order, "->'x'")
    end

    # The filter form's search object takes a sort too, as q[s]. Ransack
    # reads ransortable_attributes for that one, and for a key that is not
    # a column it reads the model's searchable associations, which
    # ApplicationRecord sets to none.
    it 'gets the residents in name order when it asks Ransack for a secret sort' do
      expect_default_order('/residents', nil, name_order, 'reset_password_token',
                           { q: { s: 'reset_password_token asc' } })
    end

    it 'still sorts by a column the page lists' do
      ids, = fetch('/residents', 'json', 'name_desc')

      expect(ids).to eq(name_order.reverse)
    end

    it 'still sorts the bills by a column of a table the page joins on purpose' do
      bill_ids_by_date

      ids, = fetch('/bills', 'json', 'residents.name_desc')

      expect(ids).to eq([cara, bob, ann].map { |cook| cook.bills.sole.id })
    end
  end

  context 'with the read-only token' do
    let(:viewer_params) { { token: token } }
    let(:token_account) { create(:admin_user, community: community, superuser: false) }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('READ_ONLY_ADMIN_TOKEN').and_return(token)
      allow(ENV).to receive(:fetch).with('READ_ONLY_ADMIN_ID', nil).and_return(token_account.id.to_s)
    end

    it_behaves_like 'a viewer who cannot sort by a secret column'
  end

  context 'when signed in as a plain admin' do
    let(:viewer_params) { {} }
    let(:admin) { create(:admin_user, community: community, superuser: false, email: 'plain@example.com') }

    before { sign_in admin }

    it_behaves_like 'a viewer who cannot sort by a secret column'

    it 'gets the admins in their default order when it asks for a password or reset column' do
      # Made in this order, so id_desc, the default, lists Zoe, Yan, then
      # the signed-in admin. The reset columns are in a third order.
      yan = create(:admin_user, community: community, email: 'yan@example.com')
      zoe = create(:admin_user, community: community, email: 'zoe@example.com')
      [[admin, 2], [yan, 3], [zoe, 1]].each do |row, rank|
        row.update_columns(reset_password_token: "admin-digest-#{rank}", encrypted_password: "hash-#{rank}",
                           reset_password_sent_at: Time.zone.local(2001, 2, rank))
      end

      %w[encrypted_password reset_password_token reset_password_sent_at current_sign_in_ip].each do |column|
        expect_default_order('/admin_users', "#{column}_asc", [zoe, yan, admin].map(&:id), column)
      end
    end

    # The lists are allowlists, so a column added by a later migration
    # cannot be sorted by until someone lists it. The column is real for
    # the length of this example: Postgres rolls an ALTER TABLE back with
    # the savepoint.
    it 'gets the residents in name order when it asks for a column added after the lists were written' do
      connection = ActiveRecord::Base.connection
      connection.transaction(requires_new: true) do
        connection.add_column(:residents, :recovery_secret, :string)
        Resident.reset_column_information
        { cara => 'b', ann => 'c', bob => 'a' }.each do |row, value|
          Resident.where(id: row.id).update_all(recovery_secret: value)
        end

        expect_default_order('/residents', 'recovery_secret_asc', name_order, 'recovery_secret')
        raise ActiveRecord::Rollback
      end
    ensure
      Resident.reset_column_information
      # ActiveAdmin keeps a page's column list from the first request
      # that needs it (ActiveAdmin::Resource#resource_attributes, and the
      # CSV builder made from it). If that request was this example's,
      # the list still names recovery_secret, and every later residents
      # CSV asks each row for a column that is gone. Forget the list.
      admin_page = ActiveAdmin.application.namespaces[:admin].resource_for(Resident)
      %i[@resource_attributes @content_columns @association_columns @default_csv_builder].each do |name|
        admin_page.remove_instance_variable(name) if admin_page.instance_variable_defined?(name)
      end
    end
  end
end
