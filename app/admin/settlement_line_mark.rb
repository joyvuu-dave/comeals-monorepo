# typed: false
# frozen_string_literal: true

# ADR 0011 rule 8: each line of a settlement can be marked Paid or Let go,
# with a note, or have its mark taken off. The form is on the settlement
# page (SettlementMarkHelper), and it posts here. A resource of its own,
# with only create, so the permission asked is the one for a mark: any
# admin may mark a line Paid (the settlement's own model is superuser-
# only), and setting or changing a Let go mark needs a superuser
# (SuperuserAdapter, :let_go), because somebody covers the amount let go.
# The form sends the newest mark it showed (`seen`), and a line whose mark
# changed after the page was loaded is not changed (SettlementLineMarking).
ActiveAdmin.register SettlementLineMark do
  menu false
  config.filters = false
  actions :create

  controller do
    def create
      authorize! :create, SettlementLineMark
      line = ReconciliationBalance.includes(:resident).find(params.require(:line_id))
      seen = Integer(params[:seen].to_s, 10, exception: false)
      status = params.require(:status).to_s
      authorize! :let_go, SettlementLineMark if let_go?(status, line, seen)
      # Read before the mark: the marking reloads the line under its lock,
      # and a read after the commit can fail for a mark that is saved
      # (spec/requests/no_query_after_commit_spec.rb).
      name = line.resident.name

      mark = SettlementLineMarking.mark!(line, status: status, note: params[:note], by: current_admin_user_custom,
                                               seen: seen)
      redirect_to admin_reconciliation_path(line.reconciliation_id), notice: "#{name}: #{mark.words}."
    rescue SettlementLineMarking::Changed, SettlementLineMarking::NothingChanged => e
      redirect_to admin_reconciliation_path(line.reconciliation_id), alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_reconciliation_path(line.reconciliation_id),
                  alert: e.record.errors.full_messages.to_sentence
    end

    private

    # The change sets Let go, or changes the Let go mark the page showed.
    def let_go?(status, line, seen)
      status == SettlementLineMark::LET_GO || line.marks.find_by(id: seen)&.status == SettlementLineMark::LET_GO
    end
  end
end
