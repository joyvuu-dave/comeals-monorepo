# typed: strict
# frozen_string_literal: true

# A settlement claims its meals with one UPDATE that skips the model
# (Settlement#assign_meals), so the audited gem writes no history row for
# it, and a dinner's history never said it was settled. This writes the
# row a save of reconciliation_id would have written, one for each
# claimed meal, inside the settlement's transaction: the history then
# says "Meal settled (settlement N)" (AuditDescription). Each row takes
# its meal's next version, and the person, request and address the
# audited gem would have read: the admin who settled, or nobody for the
# nightly task. Two queries for any number of meals: the versions, then
# one INSERT.
module SettledMealHistory
  extend T::Sig

  sig { params(meal_ids: T::Array[Integer], reconciliation_id: Integer).void }
  def self.record(meal_ids:, reconciliation_id:)
    return if meal_ids.empty?

    versions = T.let(Audited::Audit.where(auditable_type: 'Meal', auditable_id: meal_ids).group(:auditable_id)
                                   .maximum(:version), T::Hash[Integer, Integer])
    # Stamped with the time of the write, as audited stamps a row. Left
    # to insert_all, it would be the time the transaction began.
    by = writer.merge(created_at: Time.current)
    Audited::Audit.insert_all!(meal_ids.map do |id|
      { auditable_type: 'Meal', auditable_id: id, action: 'update', version: versions.fetch(id, 0) + 1,
        audited_changes: { 'reconciliation_id' => [nil, reconciliation_id] }, **by }
    end)
  end

  # Who a history row written now names, read the way the audited gem
  # reads it (Audited::Audit#set_audit_user, #set_request_uuid and
  # #set_remote_address): the user set by Audited.audit_class.as_user,
  # else the one the controller hands it, then the request's id and
  # address. A user that is a name, not a record, is kept as the name.
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.writer
    user = ::Audited.store[:audited_user] || ::Audited.store[:current_user]&.call
    who = if user.is_a?(String) then { user_type: nil, user_id: nil, username: user }
          elsif user then { user_type: user.class.name, user_id: user.id, username: nil }
          else { user_type: nil, user_id: nil, username: nil }
          end
    who.merge(request_uuid: ::Audited.store[:current_request_uuid] || SecureRandom.uuid,
              remote_address: ::Audited.store[:current_remote_address])
  end
  private_class_method :writer
end
