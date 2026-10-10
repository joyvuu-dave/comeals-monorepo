# typed: false
# frozen_string_literal: true

# The table of differences on a ledger check run page
# (app/admin/ledger_check_run.rb).
#
# LedgerVerification stores each difference as { resident_id, stored,
# source }, inside a detail that names the check that found it. The same
# keys mean a different thing in each check, so every row says which
# check found it, in words:
#
#   recompute    `source` is the person's balance rebuilt from bills and
#                sign-ups.
#   line_items   `source` is the sum of the person's meal lines. With no
#                resident, it is the sum of all of the settlement's meal
#                lines, which must be zero, and there is no stored side.
#
# The stored shape never changes, because every past run uses it. A run
# from before the line items (2026-08-02) has no check label at all: the
# recompute check was the only one then, so that is how it is read.
#
# Amounts are stored as strings, never JSON numbers, which are floats.
# They become BigDecimal here, and the words say the direction, never a
# sign (BalanceDisplayHelper).
class LedgerCheckFindingsTable < Arbre::Component
  builder_method :ledger_check_findings_table

  # The words for each check this page knows: the check itself, and a
  # side the check found nothing on.
  CHECKS = {
    'recompute' => { name: 'Balance rebuilt from bills and sign-ups', nothing_found: 'No balance' },
    'line_items' => { name: 'Sum of their meal lines', nothing_found: 'No meal lines' }
  }.freeze

  Finding = Struct.new(:reconciliation, :check, :resident_id, :stored, :source, keyword_init: true)

  def build(run)
    findings = findings_of(run)
    residents = Resident.where(id: findings.filter_map(&:resident_id)).index_by(&:id)

    table_for findings do
      column('Reconciliation', &:reconciliation)
      column('Check') { |finding| check_name(finding) }
      column('Resident') { |finding| resident_cell(finding, residents) }
      column('Stored balance') { |finding| stored_cell(finding) }
      column('What the check found') { |finding| found_cell(finding) }
    end
  end

  private

  def findings_of(run)
    run.details.flat_map do |detail|
      detail['differences'].map do |difference|
        Finding.new(reconciliation: "##{detail['reconciliation_id']} (#{detail['date']})",
                    check: detail.fetch('check', 'recompute'), resident_id: difference['resident_id'],
                    stored: difference['stored'], source: difference['source'])
      end
    end
  end

  # A label this page does not know is shown as stored.
  def check_name(finding)
    return 'Sum of all meal lines' if whole_settlement?(finding)

    CHECKS.dig(finding.check, :name) || finding.check
  end

  def resident_cell(finding, residents)
    return 'Whole settlement' if finding.resident_id.nil?

    resident = residents[finding.resident_id]
    return "Resident ##{finding.resident_id} (not found)" if resident.nil?

    link_to resident.name, admin_resident_path(resident)
  end

  # The whole settlement has no stored balance to compare.
  def stored_cell(finding)
    return if whole_settlement?(finding)
    return 'No balance stored' if finding.stored.nil?

    exact_balance_tag(BigDecimal(finding.stored))
  end

  def found_cell(finding)
    return "#{lines_total_words(BigDecimal(finding.source))} They must be equal." if whole_settlement?(finding)
    return nothing_found(finding) if finding.source.nil?

    exact_balance_tag(BigDecimal(finding.source))
  end

  # A check this page does not know gets plain words.
  def nothing_found(finding)
    CHECKS.dig(finding.check, :nothing_found) || 'No row'
  end

  # LedgerVerification#lines_do_not_balance: the line items check, with
  # no resident.
  def whole_settlement?(finding)
    finding.check == 'line_items' && finding.resident_id.nil?
  end
end
