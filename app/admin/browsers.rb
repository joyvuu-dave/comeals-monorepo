# typed: false
# frozen_string_literal: true

# Page loads by month, browser, version, system, device, and the result
# of the browser check in index.html, from browser_counts. It answers
# "which browsers and devices do residents use, and how many were turned
# away?", which is what the owner reads before changing the browsers the
# build supports (app/frontend/browser_target.mjs).
#
# Any admin may read it. The read-only token in the settlement emails may
# not (SuperuserAdapter::TOKEN_READABLE_PAGES). Nothing on it can be
# changed: the counts are written by BrowserReportJob only.
ActiveAdmin.register_page 'Browsers' do
  menu priority: 90, label: 'Browsers'

  content title: 'Browsers' do
    para 'Each time a browser opens Comeals, it runs a check before the app starts, and sends one report. ' \
         'These are those reports, added up by month. "passed" means the app started. "failed" means the ' \
         'browser was too old, or blocked cookies, and the person saw a message saying what to do. ' \
         '"error" means the check itself broke, and the app started anyway. A browser that runs no ' \
         'scripts at all sends nothing, and is not counted.'
    para 'An iPad is counted as iPadOS. The version is the browser\'s own. On an iPad or iPhone, Safari\'s ' \
         'version is the system\'s version. No system version is kept: newer browsers do not send the real one.'

    rows = BrowserCount.by_month.to_a
    if rows.empty?
      para 'No page loads have been counted yet.'
    else
      rows.group_by(&:month).each do |month, month_rows|
        panel month.strftime('%B %Y') do
          table_for month_rows do
            column('Browser', &:browser)
            column('Version') { |row| row.major || 'unknown' }
            column('System', &:os)
            column('Device', &:device)
            column('Check', &:result)
            column('Page loads', &:loads)
          end
        end
      end
    end
  end
end
