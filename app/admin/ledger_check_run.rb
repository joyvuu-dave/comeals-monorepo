# typed: false
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
         'And for each settled dinner, it checks that its rows add up to ' \
         'what it was settled at plus its corrections. ' \
         'Each run writes one row on this page, pass or fail.'
    para do
      status_tag 'all match', class: 'ok'
      text_node ' — every stored balance is still exactly what the source ' \
                'data produces. Nothing settled has changed.'
    end
    para do
      status_tag 'mismatched', class: 'error'
      text_node ' — a stored balance no longer agrees with the balance ' \
                'rebuilt from bills and sign-ups, or with the sum of that ' \
                "person's meal lines, or a settlement's meal lines no longer " \
                'add up to $0.00, or a settled dinner no longer adds up to ' \
                'what it was settled at plus its corrections. Something ' \
                'changed settled data after settlement. The run page lists ' \
                'each difference and the check that found it. See ' \
                'docs/runbooks/settled-data-repair.md.'
    end
    para do
      status_tag 'did not finish', class: 'error'
      text_node ' — the check itself crashed before it could compare ' \
                'everything. The error is on the run page. If it found ' \
                'nothing before the crash, this says nothing about the ' \
                'ledger either way. If it found a difference first, the ' \
                'label starts with how many mismatched, and those ' \
                'differences are real: they are listed on the run page.'
    end
  end

  # INDEX
  index do
    column :started_at
    column('Checked', &:reconciliations_checked)
    # A difference found before a crash is a fact about the books, so the
    # count comes first and the crash second.
    column('Result') do |run|
      if run.failed?
        label = "#{run.mismatch_count} mismatched"
        label += ', did not finish' if run.errored?
        status_tag label, class: 'error'
      elsif run.errored?
        status_tag 'did not finish', class: 'error'
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
      # Each row says which check found it: the same stored keys mean a
      # different thing in each (LedgerCheckFindingsTable).
      panel 'What disagreed' do
        ledger_check_findings_table(resource)
      end
    end
  end
end
