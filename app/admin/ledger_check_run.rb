# frozen_string_literal: true

ActiveAdmin.register LedgerCheckRun do
  menu label: 'Ledger Checks'

  # CONFIG
  config.filters = false

  # Read-only, and not because of an authorization rule. There is no way to
  # write one of these by hand at all: LedgerCheckRun refuses update and
  # destroy, and a database trigger refuses them again for anything that
  # skips Rails. The rows are written by ledger:verify and nothing else.
  #
  # This page exists so the record is visible. A control nobody can see is
  # only half a control — the question it answers is "show me that you
  # looked", and that is a question someone asks by looking.
  actions :index, :show

  scope('All', default: true, &:recent)

  # INDEX
  index do
    column :started_at
    column('Checked', &:reconciliations_checked)
    column('Result') do |run|
      if run.errored?
        status_tag 'did not finish', class: 'error'
      elsif run.failed?
        status_tag "#{run.mismatch_count} mismatched", class: 'error'
      else
        status_tag 'ties out', class: 'ok'
      end
    end
    column('Took') { |run| "#{run.duration.round(2)}s" }
    actions
  end

  # SHOW
  show do
    attributes_table do
      row :started_at
      row :finished_at
      row('Duration') { |run| "#{run.duration.round(2)}s" }
      row :reconciliations_checked
      row :mismatch_count
      row :error
    end

    if resource.details.any?
      panel 'What disagreed' do
        # Amounts are strings on purpose — they are money, and JSON numbers
        # are floats. Rendered as stored, with no parsing on the way out.
        rows = resource.details.flat_map do |detail|
          detail['differences'].map do |difference|
            {
              reconciliation: "##{detail['reconciliation_id']} (#{detail['date']})",
              resident_id: difference['resident_id'],
              stored: difference['stored'] || '(no row)',
              source: difference['source'] || '(no row)'
            }
          end
        end

        table_for rows do
          column('Reconciliation') { |row| row[:reconciliation] }
          column('Resident') { |row| row[:resident_id] }
          column('Stored at settlement') { |row| row[:stored] }
          column('Source data says') { |row| row[:source] }
        end
      end
    end
  end
end
