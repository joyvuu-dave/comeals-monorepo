# frozen_string_literal: true

namespace :reconciliations do
  desc 'Queue the common house mail about the latest reconciliation, if it has not gone out yet.'
  task send_common_house_collection_email: :environment do
    reconciliation = Reconciliation.last
    abort 'There is no reconciliation yet, so there are no balances to mail.' if reconciliation.nil?

    # Queued, not sent here, like the cook mail task: CommonHouseMailJob
    # records each send and sends nothing when it finds the record, so
    # this task does not send a second copy of a mail already recorded.
    # The Solid Queue worker must be running to send it.
    CommonHouseMailJob.perform_later(reconciliation)
    Rails.logger.info("Common house mail: queued CommonHouseMailJob for reconciliation ##{reconciliation.id}. " \
                      'It sends the mail if it has not gone out yet.')
  end
end
