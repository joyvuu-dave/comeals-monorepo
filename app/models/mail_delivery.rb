# frozen_string_literal: true

# A record that one email went out: which mailer, about which record, to
# which resident, when. Append-only at the database (a trigger refuses
# UPDATE and DELETE), so it is a fact, not a flag.
#
# Every mail run that goes to many people reads this first and mails only
# the people without a row, then writes a row after each send. So a run
# that stops part way — a dyno restart, the per-run cap, one bad address —
# can run again and reach only the people it missed. The row is written
# after the send, not before: if the process dies between the two, that
# one person gets a second copy, which is better than never getting one.
# == Schema Information
#
# Table name: mail_deliveries
#
#  id          :bigint           not null, primary key
#  about_type  :string           not null
#  mailer      :string           not null
#  sent_at     :datetime         not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  about_id    :bigint           not null
#  resident_id :bigint           not null
#
# Indexes
#
#  index_mail_deliveries_one_per_person  (mailer,about_type,about_id,resident_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (resident_id => residents.id)
#
class MailDelivery < ApplicationRecord
  belongs_to :resident
  belongs_to :about, polymorphic: true

  validates :mailer, :sent_at, presence: true
  validates :resident_id, uniqueness: { scope: %i[mailer about_type about_id] }

  # The residents among `residents` (a relation) who have not yet received
  # `mailer` about `about`.
  def self.not_yet_sent(residents, mailer:, about:)
    sent_ids = where(mailer: mailer, about: about).select(:resident_id)
    residents.where.not(id: sent_ids)
  end

  def self.record!(mailer:, about:, resident:)
    create!(mailer: mailer, about: about, resident: resident, sent_at: Time.current)
  end
end
