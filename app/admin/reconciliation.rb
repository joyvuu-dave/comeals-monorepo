# typed: false
# frozen_string_literal: true

ActiveAdmin.register Reconciliation do
  menu label: 'Reconciliations'

  # CONFIG
  config.filters = false

  # Reconciliations are append-only settlement events: once created, the
  # cutoff, the swept meals, and the persisted balances are the record that
  # cooks were notified of and paid against. No edit, update, or destroy —
  # corrections settle as new entries in the next reconciliation (the model
  # enforces this too; see Reconciliation#reject_update / #reject_destroy).
  # The one exception is not on this page: Settlement#correct!, which a
  # migration runs after it fixes a settled meal's rows, works the numbers
  # out again. This page then shows the new numbers like any other
  # settlement's, and the record of the correction stays in the database
  # (docs/runbooks/settled-data-repair.md has the query).
  actions :index, :show, :new, :create

  permit_params :end_date

  # ADR 0011 rule 4: the new form asks for a cutoff and shows a preview,
  # and the Create button is on the preview. The preview shows the
  # dinners that will settle, each person's amount, and the dinners that
  # will wait and why (app/views/admin/reconciliations/preview.html.arb).
  # It writes nothing, but it is the first step of a settlement, so it
  # needs the same permission as the new form: a superuser. A plain admin
  # reads the settlements once they are made.
  collection_action :preview, method: :get do
    # Hand-written action: ActiveAdmin authorizes inside resource and
    # build_resource, neither of which runs here (the meal_resident.rb
    # trap, ADR 0004).
    authorize! :new, Reconciliation
    @reconciliation = Reconciliation.new(end_date: params.dig(:reconciliation, :end_date))
    cutoff = @reconciliation.end_date
    refusal = cutoff ? Reconciliation.cutoff_refusal(cutoff, Community.instance.today) : "can't be blank"
    if refusal
      # The new form again, with the reason on the date, in the words the
      # create validation would use.
      @reconciliation.errors.add(:end_date, refusal)
      render :new
    else
      @page_title = 'Settlement Preview'
      @preview = Settlement.preview(cutoff: cutoff)
    end
  end

  # The button under the dinners that wait for a cost: "Mark these N
  # blank costs as No cost". The GET shows the list and asks yes or no;
  # the yes posts the costs it showed, and NoCostMarking changes only
  # those still blank (app/views/admin/reconciliations/mark_no_cost.html.arb).
  # It writes bills, so it needs a superuser, like the bill form.
  collection_action :mark_no_cost, method: %i[get post] do
    authorize! :update, Bill
    cutoff = Date.iso8601(params.dig(:reconciliation, :end_date).to_s)
    preview_path = preview_admin_reconciliations_path(reconciliation: { end_date: cutoff.iso8601 })
    if request.post?
      result = NoCostMarking.call(bill_ids: Array(params[:bill_ids]).map { |id| Integer(id, 10) })
      redirect_to preview_path, notice: helpers.no_cost_marking_words(result)
    else
      @page_title = 'Mark Blank Costs as No Cost'
      @cutoff = cutoff
      @waiting = Settlement.waiting_by(cutoff, today: Community.instance.today)
      redirect_to preview_path, notice: 'No cost is blank on a dinner that waits.' if @waiting.empty?
    end
  rescue Date::Error
    redirect_to new_resource_path, alert: 'Pick a cutoff date first.'
  end

  controller do
    # The preview's Create button settles a period, the same way the
    # nightly task and the API do: SettleAndNotify claims the meals,
    # writes the ledger, queues the cook mail, and refreshes the running
    # balances (#73). Nothing after its commit can raise, so the conflict
    # rescue's "Nothing was saved" is only ever shown for a settlement
    # that was not saved. build_resource runs the authorization check and
    # permits the params; the row it builds is only read for its cutoff,
    # because a retry after a conflict needs a fresh row each time
    # (RetryOnConflict). A refused settlement comes back as RecordInvalid
    # with the errors on its row, which the form renders like any failed
    # save.
    #
    # The button sends the preview's fingerprint, and the settlement
    # refuses to commit anything the preview did not show
    # (Settlement.fingerprint). A create without one did not come from a
    # preview, so it is sent to the preview first.
    def create
      cutoff = build_resource.end_date
      fingerprint = params[:fingerprint].presence
      unless fingerprint
        return redirect_to(preview_for(cutoff), alert: 'Look over the preview first, then click Create.')
      end

      # A person is waiting at a form, so the request's three quick tries,
      # not the nightly task's minutes (SettleAndNotify::REQUEST).
      reconciliation = SettleAndNotify.call(cutoff: cutoff, retries: SettleAndNotify::REQUEST,
                                            fingerprint: fingerprint).reconciliation
      redirect_to resource_path(reconciliation), notice: 'Reconciliation was successfully created.'
    rescue ActiveRecord::RecordInvalid => e
      set_resource_ivar(e.record)
      render :new
    rescue Settlement::Changed
      redirect_to preview_for(cutoff),
                  alert: 'A cost or a sign-up changed after this preview was made, so nothing was saved. ' \
                         'This is the preview as it is now. Look it over, then click Create again.'
    rescue Settlement::Contested
      # Another settlement claimed the meals between this one's read and
      # its write. Nothing was written, and the period may be settled
      # already. RetryOnConflict does not cover this — it retries only a
      # refusal from the database — and the conflict rescue in
      # config/initializers/active_admin_conflict_rescue.rb does not
      # either, because Contested is not an ActiveRecord error. So it
      # answered 500 until now.
      redirect_to new_resource_path,
                  alert: 'Someone else was settling at the same time. Nothing was saved. Try again.'
    end

    private

    # The preview for a cutoff, or the new form when there is no cutoff.
    def preview_for(cutoff)
      return new_resource_path unless cutoff

      preview_admin_reconciliations_path(reconciliation: { end_date: cutoff.iso8601 })
    end
  end

  # INDEX
  index do
    column :date
    column :end_date
    column :number_of_meals, sortable: false
    actions
  end

  # SHOW
  show do
    attributes_table do
      row :date
      row :end_date
      row :number_of_meals
    end

    # Each line's unit is the one saved with it, on the day of the
    # settlement (ADR 0011 rule 7), so these totals never change later.
    # A settlement made before units were saved says whose units it shows,
    # and has no Moved out line (Reconciliation#records_who_moved_out?).
    moved_out_known = reconciliation.records_who_moved_out?
    unless moved_out_known
      para "This settlement was made before the app saved each person's unit. These are the units people " \
           "live in, or last lived in, on #{reconciliation.units_recorded_on.strftime('%b %-d, %Y')}. The app " \
           'did not record who had moved out at the time.'
    end

    panel 'Settlement Balances' do
      order = moved_out_known ? 'reconciliation_balances.lived_here DESC, ' : ''
      balances = reconciliation.reconciliation_balances
                               .includes(:resident, :unit, marks: :admin_user)
                               .joins(:resident, :unit)
                               .order(Arel.sql("#{order}units.name, residents.name"))

      # balance_tag turns the stored sign into words — see BalanceDisplayHelper.
      # The marks are ADR 0011 rule 8 (SettlementMarkHelper). A read-only
      # token sees them, and no form.
      table_for balances do
        column('Resident') { |rb| link_to rb.resident.name, admin_resident_path(rb.resident) }
        column('Unit') { |rb| rb.lived_here || !moved_out_known ? rb.unit.name : 'Moved out' }
        column('Balance') { |rb| balance_tag(rb.amount) }
        column('Mark') { |rb| settlement_mark_words(rb.current_mark) }
        if authorized?(:create, SettlementLineMark)
          let_go_allowed = authorized?(:let_go, SettlementLineMark)
          action = admin_settlement_line_marks_path
          column('Change mark') { |rb| settlement_mark_form(action, rb, let_go_allowed: let_go_allowed) }
        end
      end

      text_node settlement_totals_tag(balances.map(&:amount), 'residents')
    end

    # Every mark on this settlement's lines, newest first: each change is
    # kept (ADR 0011 rule 8).
    marks = SettlementLineMark.joins(:reconciliation_balance)
                              .where(reconciliation_balances: { reconciliation_id: reconciliation.id })
                              .includes(:admin_user, reconciliation_balance: :resident)
                              .order(id: :desc).to_a
    if marks.any?
      panel "Marks (#{marks.size})" do
        table_for marks do
          column('Made') { |mark| mark.created_at.strftime('%b %-d, %Y %-l:%M %p') }
          column('Resident') { |mark| mark.reconciliation_balance.resident.name }
          column('Mark', &:words)
          column('Note') { |mark| mark.note.to_s }
          column('By') { |mark| mark.admin_user.email }
        end
      end
    end

    # The people who had moved out by the day of the settlement are on a
    # line of their own, not in any unit, so the lines still add up to $0.00.
    panel 'Unit Balances' do
      unit_bals = reconciliation.unit_balances
      rows = unit_bals.map { |(unit_id, unit_name), amount| [link_to(unit_name, admin_unit_path(unit_id)), amount] }
      rows << ['Moved out', reconciliation.moved_out_balance] if moved_out_known
      table_for rows do
        column('Unit') { |name, _| name }
        column('Balance') { |_, amount| balance_tag(amount) }
      end

      text_node settlement_totals_tag(rows.map(&:last), 'units')
    end

    panel 'Meals' do
      # Read-only record of the meals this settlement swept. Corrections are
      # never made by editing the set — they settle as new entries in the next
      # reconciliation.
      settled_meals = reconciliation.meals.includes(:meal_charges, bills: :resident).order(:date)

      table_for settled_meals do
        column('Date') { |m| link_to m.date.to_s, admin_meal_path(m) }
        column('Cooks') do |m|
          cooks = m.bills.map(&:resident).uniq.sort_by(&:name)
          cooks.empty? ? '—' : safe_join(cooks.map { |c| link_to(c.name, admin_resident_path(c)) }, ', ')
        end
        # From the stored charges — what this settlement actually used.
        # Blank for zero or for a settlement from before line items
        # existed and never corrected since, like every other cost cell
        # (meal_cost_cell).
        column('Total Cost') { |m| meal_cost_cell(m, :total_cost) }
      end
    end

    # The corrections to earlier settlements' dinners that this settlement
    # carries (ADR 0011 rule 6). Their lines are in the balances above.
    corrections = reconciliation.meal_corrections.includes(:meal, :admin_user, lines: :resident).to_a
    if corrections.any?
      panel "Corrections Carried (#{corrections.size})" do
        residents = CorrectionWords.residents_named_in(corrections)
        corrections.each do |correction|
          h4 { link_to "Correction to the #{correction.meal.date.iso8601} dinner", admin_meal_path(correction.meal) }
          meal_correction_details(correction, residents: residents)
        end
      end
    end
  end

  # FORM
  # The form asks for the cutoff and opens the preview, which has the
  # Create button. A GET, because a preview writes nothing.
  form url: '/reconciliations/preview', method: :get do |f|
    f.inputs do
      latest = Reconciliation.latest_cutoff(Community.instance.today)
      f.input :end_date, as: :datepicker,
                         hint: 'Settle all unreconciled meals up to this date. It must be on or before ' \
                               "#{latest.iso8601}, #{Reconciliation::DAYS_TO_WAIT} days before today, so cooks " \
                               'have time to fix their costs.'
    end
    f.actions do
      f.action :submit, label: 'Preview', button_html: { name: nil }
      f.cancel_link
    end
    f.semantic_errors
  end
end
