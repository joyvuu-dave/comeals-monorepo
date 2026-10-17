# typed: true
# frozen_string_literal: true

class ReconciliationMailer < ApplicationMailer
  helper BalanceDisplayHelper

  # Where the common house email goes.
  COMMON_HOUSE = 'commonhouse@swansway.com'

  # Sent to each cook after a settlement has committed, so the meals in
  # it are already locked (#106). The date in the mail is end_date, the
  # settlement's cutoff. A cook is someone who cooked a meal in the
  # settlement, or whose cost a correction it carries changed
  # (NotifyCooksJob.cook_rows), so the mail says each part only to the
  # cooks it is about. A settlement may carry corrections and settle no
  # meal (ADR 0011 rule 6).
  def reconciliation_notify_email(resident, reconciliation)
    @resident = resident
    @community = @resident.community
    @settled_through = T.must(reconciliation.end_date).strftime('%b %-d, %Y')
    @settles_meals = reconciliation.meals.exists?
    @cooked = reconciliation.settled_cook?(resident)
    @corrections = corrections_of(resident, reconciliation)
    @corrections_heading = corrections_heading(@corrections.size)
    # The cook's dinners in this settlement, at what each was settled at
    # (#177). The bills page would show each cost as it is now.
    @url = "#{root_admin_url}/reconciliations/#{reconciliation.id}/cook?resident_id=#{resident.id}" \
           "&subdomain=admin&token=#{read_only_token}" \
           '&utf8=%E2%9C%93'
    mail(to: @resident.email, subject: "Common meals settled through #{@settled_through}")
  end

  # Sent to the common house after a settlement (ADR 0011 rule 9): what
  # each person owes or is owed in it, by unit, then the people who had
  # moved out (CollectionList), and a read-only link to the settlement's
  # page. These are the settlement's own numbers. The running balances
  # leave out every meal it settled (#165).
  def common_house_collection_email(reconciliation)
    @community = T.must(reconciliation.community)
    @settled_through = T.must(reconciliation.end_date).strftime('%b %-d, %Y')
    @list = CollectionList.new(reconciliation)
    if reconciliation.units_recorded_later?
      @units_saved_on = T.must(reconciliation.units_recorded_on).strftime('%b %-d, %Y')
    end
    @url = "#{root_admin_url}/reconciliations/#{reconciliation.id}?subdomain=admin&token=#{read_only_token}" \
           '&utf8=%E2%9C%93'
    mail(to: COMMON_HOUSE,
         subject: "Balances to collect: common meals settled through #{@settled_through}")
  end

  private

  # Each correction this settlement carries that changed this cook's
  # cost, by the dinner's date: the date, a sentence for each change to
  # their cost, the reason, and a read-only link to the dinner's page,
  # which shows the whole correction.
  def corrections_of(resident, reconciliation)
    named = { resident.id => resident }
    reconciliation.meal_corrections.includes(:meal).sort_by { |correction| [correction.meal.date, correction.id] }
                  .filter_map do |correction|
      edits = correction.cost_edits_of(resident)
      next if edits.empty?

      { date: correction.meal.date.strftime('%b %-d, %Y'),
        words: edits.map { |edit| CorrectionWords.edit(edit, named) }.join(' '),
        reason: correction.reason,
        url: "#{root_admin_url}/meals/#{correction.meal_id}?subdomain=admin&token=#{read_only_token}" \
             '&utf8=%E2%9C%93' }
    end
  end

  def corrections_heading(count)
    if count == 1
      'An admin corrected your cost on a meal settled before. This settlement carries the change:'
    else
      "An admin corrected your cost on #{count} meals settled before. This settlement carries the changes:"
    end
  end

  # The read-only admin token, written as a query value. CGI.escape
  # writes each character that has a meaning in a URL ("+", "&", "#",
  # "%") as a %-code, so the admin reads back the same token.
  def read_only_token
    CGI.escape(ENV.fetch('READ_ONLY_ADMIN_TOKEN', nil).to_s)
  end
end
