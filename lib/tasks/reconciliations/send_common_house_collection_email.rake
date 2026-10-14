# frozen_string_literal: true

namespace :reconciliations do
  desc 'Queue the common house mail about the latest reconciliation, if it has not gone out yet.'
  task send_common_house_collection_email: :environment do
    reconciliation = Reconciliation.last
    abort 'There is no reconciliation yet, so there are no balances to mail.' if reconciliation.nil?

    # Queued, not sent here, like the cook mail task: CommonHouseMailJob
    # sends it once per settlement and records that it did, so this task
    # cannot send a second copy of a mail the settlement already sent.
    # The Solid Queue worker must be running to send it.
    CommonHouseMailJob.perform_later(reconciliation)
    Rails.logger.info("Common house mail: queued CommonHouseMailJob for reconciliation ##{reconciliation.id}. " \
                      'It sends the mail if it has not gone out yet.')
  end
end
