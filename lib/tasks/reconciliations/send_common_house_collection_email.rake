# frozen_string_literal: true

namespace :reconciliations do
  desc 'Mail the common house what each person owes or is owed in the latest reconciliation.'
  task send_common_house_collection_email: :environment do
    reconciliation = Reconciliation.last
    abort 'There is no reconciliation yet, so there are no balances to mail.' if reconciliation.nil?

    start_time = Time.current

    begin
      ReconciliationMailer.common_house_collection_email(reconciliation).deliver_now
    rescue *MAIL_DELIVERY_ERRORS => e
      MailDeliveryFailure.report(e, mailer: 'common_house_collection_email')
    end

    total_time = Time.current - start_time
    Rails.logger.info("Common House Reconciliation Email task Complete in #{total_time}s.")
  end
end
