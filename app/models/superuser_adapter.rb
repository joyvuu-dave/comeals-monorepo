# frozen_string_literal: true

# Admin authorization. Three levels, described in full in
# docs/adr/0004-admin-authorization.md.
#
#   read-only token  — reads an allowlist of resources, writes nothing
#   admin            — reads everything, writes everything except the ledger
#   superuser        — everything
#
# Two rules do the work:
#
#   1. A request that authenticated with READ_ONLY_ADMIN_TOKEN is read-only,
#      whatever tier its backing AdminUser has, and may only reach the
#      resources the emails link to.
#   2. Writing anything on the money path, or anything that decides who may
#      act, requires a superuser. Everything else is open to any admin.
class SuperuserAdapter < ActiveAdmin::AuthorizationAdapter
  # The money path. A write to any of these changes what somebody owes or is
  # owed, so it is superuser-only.
  #
  # Meal is on the list even though creating a meal is ordinary community
  # admin. Its `closed` and `max` fields and its nested guests all feed the
  # cost split, and ActiveAdmin authorizes per resource, not per field — so
  # the whole resource is restricted. Erring the other way would put a
  # money-changing field behind a non-money permission.
  #
  # Resident is deliberately NOT on the list, even though residents carry a
  # `multiplier` price category. Attendance snapshots its own multiplier into
  # meal_residents.multiplier when the row is created, so editing a resident
  # never reaches back into a settled meal. Adding and retiring residents is
  # exactly the day-to-day work a non-money admin is for.
  LEDGER_MODELS = %w[
    Bill Guest Meal MealResident Reconciliation ReconciliationBalance ResidentBalance
  ].freeze

  # Not money, but restricted for a related reason: these decide who may act.
  # AdminUser grants and revokes the superuser flag. Community holds `cap`,
  # which changes every subsidized meal's settlement math.
  GOVERNANCE_MODELS = %w[AdminUser Community].freeze

  SUPERUSER_ONLY_MODELS = (LEDGER_MODELS + GOVERNANCE_MODELS).freeze

  # What a read-only token link may reach. These are the resources the
  # reconciliation emails link to, plus what those pages link on to.
  #
  # Nothing here is private: attendance and cook costs are already on the
  # community calendar, and a balance is derived from exactly that data. The
  # allowlist exists to keep a link mailed to the whole community from also
  # being a way to enumerate admin accounts and resident birthdays, which is a
  # different kind of information that happens to sit behind the same read
  # permission.
  TOKEN_READABLE_MODELS = %w[Bill Meal Reconciliation Resident Unit].freeze

  READ_ACTIONS = %i[read].freeze

  # The two actions that make a new record. ActiveAdmin asks about :new to
  # decide whether to draw the "New" button and about :create to run the form
  # submit, so a rule has to cover both.
  CREATE_ACTIONS = %i[new create].freeze

  def authorized?(action, subject = nil)
    return token_authorized?(action, subject) if Current.read_only_admin_token

    return false if creating_a_second_community?(action, subject)
    return true if READ_ACTIONS.include?(action)
    return true if user&.superuser?

    # Any signed-in admin may write, except on the restricted models. A nil or
    # unrecognized subject fails closed: if we cannot tell what is being
    # written, we do not let a non-superuser write it.
    model = model_name(subject)
    model.present? && SUPERUSER_ONLY_MODELS.exclude?(model)
  end

  private

  # The communities table holds exactly one row. Creating it is a bootstrap
  # step on an empty database, and once the row exists there is nothing left
  # to create, so both the button and the actions go away — for a superuser
  # too. The model's enforce_singleton validation still refuses a second row
  # if a write ever gets past this.
  #
  # This lives in the adapter rather than in app/admin/community.rb because
  # ActiveAdmin asks the adapter the same question to draw the button and to
  # run the action. One rule then covers both, and the button can never show
  # up pointing at an action that refuses.
  def creating_a_second_community?(action, subject)
    CREATE_ACTIONS.include?(action) && model_name(subject) == 'Community' && Community.exists?
  end

  # Token requests read, and only from the allowlist. Writes are refused here
  # rather than in the controller so the rule cannot be widened by pointing
  # READ_ONLY_ADMIN_ID at a superuser account — the token path is read-only by
  # construction, not because of which row it happens to resolve to.
  def token_authorized?(action, subject)
    return false unless READ_ACTIONS.include?(action)

    model = model_name(subject)
    # Pages rather than models (the Dashboard) have no model to check. The
    # Dashboard is also where ActiveAdmin redirects an unauthorized request,
    # so refusing it here would turn every denial into a redirect loop.
    return true if model.nil?

    TOKEN_READABLE_MODELS.include?(model)
  end

  # ActiveAdmin passes an instance for row-level checks and the class when it
  # decides whether to draw a menu item, so both have to resolve to the same
  # name. Anything that is not an ActiveRecord model (an ActiveAdmin::Page,
  # nil) returns nil and is handled by the caller.
  def model_name(subject)
    klass = subject.is_a?(Class) ? subject : subject.class
    return nil unless klass.respond_to?(:ancestors) && klass.ancestors.include?(ActiveRecord::Base)

    klass.name
  end
end
