# frozen_string_literal: true

namespace :reconciliations do
  desc 'Send Common House Committee links to balance pages for current reconciliation period.'
  task send_common_house_collection_email: :environment do
    start_time = Time.current

    begin
      ReconciliationMailer.common_house_collection_email.deliver_now
    rescue *MAIL_DELIVERY_ERRORS => e
      MailDeliveryFailure.report(e, mailer: 'common_house_collection_email')
    end

    total_time = Time.current - start_time
    Rails.logger.info("Common House Reconciliation Email task Complete in #{total_time}s.")
  end
end
