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

  # The page must explain itself. This record answers "show me that you
  # looked", and the person looking may be a future admin — or future us —
  # who no longer remembers what the check does.
  sidebar 'What this page shows', only: %i[index show] do
    para 'Once settled, a reconciliation must never change. Every night, ' \
         'the ledger:verify task proves it has not: for each settled ' \
         'reconciliation, it rebuilds the balances from the source rows ' \
         '(bills, attendance, guests) and compares them to the balances ' \
         'stored at settlement time. It also adds up the per-meal charge ' \
         'lines and compares those sums to the same stored balances. ' \
         'Each run writes one row on this page, pass or fail.'
    para do
      status_tag 'all match', class: 'ok'
      text_node ' — every stored balance is still exactly what the source ' \
                'data produces. Nothing settled has changed.'
    end
    para do
      status_tag 'mismatched', class: 'error'
      text_node ' — a stored balance no longer agrees with its source ' \
                'data. Something changed settled data after settlement. ' \
                'The differences are listed on the run page. See ' \
                'docs/runbooks/settled-data-repair.md.'
    end
    para do
      status_tag 'did not finish', class: 'error'
      text_node ' — the check itself crashed before it could compare ' \
                'everything. The error is on the run page. This says ' \
                'nothing about the ledger either way.'
    end
  end

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
        status_tag 'all match', class: 'ok'
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
