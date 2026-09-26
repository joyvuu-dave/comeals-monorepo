# frozen_string_literal: true

# Which examples mutant runs for which classes. Read by
# spec/support/mutant_selection.rb under bin/mutant, and by
# spec/config/mutant_selection_spec.rb always, which checks the lists.
#
# One rule this file has already been wrong about once: a row REPLACES
# mutant's own selection for that file. Mutant would run the examples of
# `describe LedgerVerification` for every LedgerVerification method on
# its own; a row for that file that named only the money classes turned
# that off, and every LedgerVerification mutation survived with
# "tests: 0" (2026-09-12: 661 of them). So a row for a file that
# describes a class must name that class too. The spec pins it.

# The rows as written. MUTANT_SPECS below adds the base controller to
# every request spec: every API request runs ApiController's filters and
# rescues, every admin request runs ApplicationController's, so each of
# those files proves the base class as well as the controller it names.
# The first controller run (2026-09-12) selected five files for
# ApiController and 269 of its mutations survived, "answer nothing to
# an unknown path" among them.
MUTANT_SPEC_ROWS = {
  'spec/services/settlement_allocate_to_cents_on_random_ledgers_spec.rb' => %w[Settlement],
  # The oracle comparison describes MealLedger, so it runs for MealLedger
  # on its own; this row adds it to Settlement for the rounding.
  'spec/services/meal_ledger_against_plain_ledger_spec.rb' => %w[MealLedger Settlement LargestRemainderSplit],
  # Describes LedgerVerification; the settlement it checks proves the
  # ledger's allocation at the grain and the exact zero-sum guard too.
  'spec/services/ledger_verification_line_rounding_spec.rb' => %w[LedgerVerification MealLedger Settlement],
  'spec/services/settlement_contract_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/services/ledger_verification_spec.rb' => %w[LedgerVerification Settlement Reconciliation MealLedger],
  'spec/services/settle_and_notify_spec.rb' =>
    %w[SettleAndNotify Settlement Reconciliation BalanceRecalculation RetryOnConflict NotifyCooksJob],
  'spec/services/meal_cost_summary_spec.rb' => %w[MealCostSummary MealLedger],
  'spec/models/reconciliation_spec.rb' => %w[Reconciliation Settlement MealLedger AppendOnly BelongsToTheCommunity],
  'spec/models/reconciliation_awkward_bills_spec.rb' =>
    %w[Reconciliation Settlement MealLedger AppendOnly BelongsToTheCommunity],
  'spec/models/reconciliation_balance_spec.rb' => %w[ReconciliationBalance Reconciliation Settlement AppendOnly],
  'spec/helpers/balance_display_helper_spec.rb' => %w[BalanceDisplayHelper MealLedger],
  'spec/mailers/reconciliation_mailer_spec.rb' => %w[ReconciliationMailer ApplicationMailer Reconciliation],
  'spec/mailers/resident_mailer_spec.rb' => %w[ResidentMailer ApplicationMailer],
  'spec/jobs/refresh_balances_job_spec.rb' => %w[RefreshBalancesJob BalanceRecalculation],
  'spec/tasks/settlement_matches_running_balance_spec.rb' =>
    %w[Settlement Reconciliation MealLedger BalanceRecalculation],
  'spec/tasks/billing_recalculate_correctness_spec.rb' => %w[BalanceRecalculation MealLedger],
  'spec/tasks/stored_ledger_against_plain_ledger_spec.rb' =>
    %w[BalanceRecalculation Settlement Reconciliation MealLedger],
  'spec/tasks/billing_recalculate_snapshot_spec.rb' => %w[BalanceRecalculation SnapshotRead],
  'spec/tasks/billing_recalculate_spec.rb' => %w[BalanceRecalculation RefreshBalancesJob],
  'spec/tasks/reconciliations_create_spec.rb' => %w[Settlement Reconciliation MealLedger],
  'spec/tasks/ledger_verify_spec.rb' => %w[Settlement Reconciliation LedgerVerification VerifyLedgerJob],
  # The race spec is the only one that fails when assign_meals stops
  # taking the row lock. The two trigger specs in spec/db are not here:
  # they check database triggers, which mutant does not touch, and cost
  # 20 seconds a pass.
  'spec/db/settlement_race_spec.rb' => %w[Settlement],
  # A method-level entry runs only for that method, and for that method
  # nothing else runs: this is the one caller of rewrite!, a repair step.
  'spec/db/settled_balance_triggers_spec.rb' => %w[Settlement#rewrite!],
  # The preview, create, settled-meal-cache and live-update request specs
  # prove Settlement too; their rows are in the second block, with the
  # controllers and LiveUpdate they also prove.
  'spec/tasks/reconciliations_email_spec.rb' =>
    %w[Reconciliation PacedDelivery ReconciliationMailer MailDeliveryFailure],
  'spec/requests/admin/reconciliation_show_spec.rb' => %w[Reconciliation BalanceDisplayHelper MealCostSummary],
  'spec/requests/admin/resident_statement_spec.rb' =>
    %w[Reconciliation BalanceDisplayHelper SettlementLinesTable MealCostSummary],

  # --- beyond the money path (2026-09-12) ------------------------------------
  # The same rule: a spec described by a sentence, or by the thing a class
  # is reached through, names the classes whose behaviour it checks.
  'spec/requests/asset_cache_control_spec.rb' => %w[AssetCacheControl],
  'spec/requests/api/v1/live_update_contract_spec.rb' =>
    %w[Settlement LiveUpdate Meal Rotation Bill MealResident Guest Resident Unit Community
       Event GuestRoomReservation CommonHouseReservation NotesMealLiveUpdate],
  'spec/requests/api/v1/calendar_cache_race_spec.rb' => %w[LiveUpdate Community],
  'spec/requests/api/v1/calendar_cache_recolor_race_spec.rb' => %w[LiveUpdate Rotation],
  'spec/requests/api/v1/settled_meal_cache_spec.rb' => %w[Settlement LiveUpdate],
  'spec/requests/api/v1/stale_meal_form_cache_spec.rb' => %w[LiveUpdate],
  'spec/requests/api/v1/reconciliations_preview_spec.rb' =>
    %w[Settlement Reconciliation MealLedger ReconciliationWarnings Api::V1::ReconciliationsController],
  'spec/requests/api/v1/reconciliations_create_spec.rb' =>
    %w[Settlement Reconciliation MealLedger SettleAndNotify NotifyCooksJob RetryOnConflict
       Api::V1::ReconciliationsController],
  'spec/requests/api/v1/reconciliations_authorization_spec.rb' => %w[Api::V1::ReconciliationsController],
  'spec/requests/api/v1/residents_ical_spec.rb' => %w[MealIcalFeed Api::V1::ResidentsController],
  'spec/requests/api/v1/communities_controller_spec.rb' => %w[MealIcalFeed Api::V1::CommunitiesController],
  'spec/requests/api/v1/residents_controller_spec.rb' =>
    %w[JwtAuth ResidentNameShortener PasswordReset Api::V1::ResidentsController],
  'spec/requests/api/v1/sessions_controller_spec.rb' => %w[JwtAuth Api::V1::SessionsController],
  'spec/requests/api/v1/authentication_pinning_spec.rb' => %w[JwtAuth ApiController],
  'spec/requests/api/v1/password_reset_spec.rb' => %w[PasswordReset ResidentMailer Api::V1::ResidentsController],
  'spec/requests/admin/password_reset_button_spec.rb' => %w[PasswordReset],
  'spec/requests/api/v1/meal_write_retry_spec.rb' => %w[RetryOnConflict Api::V1::MealsController],
  'spec/requests/api/v1/calendar_writes_retry_spec.rb' =>
    %w[RetryOnConflict ApiController Api::V1::EventsController Api::V1::GuestRoomReservationsController
       Api::V1::CommonHouseReservationsController],
  'spec/requests/api/v1/calendar_read_conflict_spec.rb' =>
    %w[RetryOnConflict ApiController Api::V1::CommunitiesController],
  'spec/requests/api/v1/pool_exhaustion_spec.rb' => %w[ApiController],
  'spec/requests/api/v1/update_bills_spec.rb' => %w[ThirdCookWarning Api::V1::MealsController Bill],
  'spec/requests/api/v1/meals_controller_spec.rb' =>
    %w[Api::V1::MealsController AuditDescription MealFormSerializer MealCostSummary Meal MealResident Guest],
  'spec/requests/api/v1/meals_refused_writes_spec.rb' =>
    %w[Api::V1::MealsController ReconciledMealImmutability ClosedMealAttendanceFreeze],
  'spec/requests/api/v1/meals_unknown_resident_spec.rb' => %w[Api::V1::MealsController],
  'spec/requests/api/v1/meal_cooks_performance_spec.rb' => %w[MealFormSerializer Meal],
  'spec/requests/api/v1/events_controller_spec.rb' => %w[Api::V1::EventsController Event LiveUpdate],
  'spec/requests/api/v1/guest_room_reservations_controller_spec.rb' =>
    %w[Api::V1::GuestRoomReservationsController GuestRoomReservation],
  'spec/requests/api/v1/common_house_reservations_controller_spec.rb' =>
    %w[Api::V1::CommonHouseReservationsController CommonHouseReservation],
  'spec/requests/api/v1/rotations_controller_spec.rb' => %w[Api::V1::RotationsController RotationSerializer],
  'spec/requests/api/v1/site_controller_spec.rb' => %w[Api::V1::SiteController],
  'spec/requests/api/v1/write_messages_spec.rb' =>
    %w[Api::V1::MealsController Api::V1::EventsController Api::V1::CommonHouseReservationsController
       Api::V1::GuestRoomReservationsController Api::V1::CommunitiesController Api::V1::ResidentsController
       MealIcalFeed],
  'spec/requests/admin/comments_routes_spec.rb' => %w[ApplicationController],
  'spec/requests/api/v1/high_trust_authorization_spec.rb' => %w[ApiController],
  'spec/requests/api/v1/calendar_cache_timezone_spec.rb' =>
    %w[CalendarSerializer Community Api::V1::CommunitiesController],
  'spec/requests/api/v1/calendar_last_day_spec.rb' => %w[CalendarSerializer],
  'spec/requests/api/v1/calendar_midnight_spec.rb' => %w[CalendarSerializer Community],
  'spec/requests/fallback_controller_spec.rb' => %w[FallbackController],
  'spec/requests/routing_spec.rb' => %w[FallbackController],
  'spec/requests/admin/money_field_rendering_spec.rb' => %w[MoneyFieldHelper],
  'spec/requests/admin/schedule_grid_labels_spec.rb' => %w[ScheduleWeekLabelHelper],
  'spec/requests/admin/schedule_preview_spec.rb' => %w[MealSchedule Community],
  'spec/requests/admin/superuser_authorization_spec.rb' => %w[SuperuserAdapter],
  'spec/requests/admin/superuser_management_spec.rb' => %w[SuperuserAdapter AdminUser],
  'spec/requests/admin/read_only_token_spec.rb' => %w[SuperuserAdapter ApplicationController],
  'spec/requests/admin/csrf_failure_spec.rb' => %w[ApplicationController],
  'spec/requests/admin/bootstrap_guard_spec.rb' => %w[ApplicationController],
  'spec/requests/admin/session_persistence_spec.rb' => %w[ApplicationController],
  'spec/requests/admin/reservation_forms_spec.rb' => %w[GuestRoomReservation CommonHouseReservation LiveUpdate],
  'spec/requests/admin/admin_logout_spec.rb' => %w[ApplicationController],
  'spec/requests/admin/admin_zone_spec.rb' => %w[ApplicationController],
  'spec/requests/admin/deletion_safeguards_spec.rb' => %w[RefusedDestroyMessage Meal Resident Rotation Unit],
  'spec/requests/admin/rotation_destroy_spec.rb' => %w[Rotation RefusedDestroyMessage],
  'spec/requests/admin/meal_lock_order_spec.rb' => %w[LocksItsMealFirst],
  'spec/requests/admin/meal_form_guests_spec.rb' => %w[Guest ClosedMealAttendanceFreeze],
  'spec/requests/admin/meal_form_guest_move_spec.rb' => %w[Guest ClosedMealAttendanceFreeze],
  'spec/requests/admin/attendance_correction_spec.rb' => %w[MealResident ClosedMealAttendanceFreeze],
  'spec/requests/admin/reconciled_immutability_spec.rb' => %w[ReconciledMealImmutability Bill],
  'spec/requests/admin/reconciliation_immutability_spec.rb' => %w[SettleAndNotify Reconciliation AppendOnly],
  'spec/requests/admin/child_pricing_rule_spec.rb' => %w[Community Multiplier],
  'spec/requests/admin/community_form_spec.rb' => %w[Community],
  'spec/requests/admin/community_singleton_spec.rb' => %w[Community BelongsToTheCommunity],
  'spec/requests/admin/community_creation_spec.rb' => %w[Community AdminUser],
  'spec/requests/admin/resident_form_spec.rb' => %w[Resident HasPhoneNumber],
  'spec/requests/admin/unit_form_spec.rb' => %w[Unit],
  'spec/requests/admin/meal_move_spec.rb' => %w[Bill ReconciledMealImmutability NotesMealLiveUpdate],
  'spec/tasks/community_create_rotations_spec.rb' => %w[EnsureRotationsJob Community MealSchedule Rotation],
  'spec/tasks/rotations_notify_new_spec.rb' => %w[PacedDelivery ResidentMailer MailDelivery],
  'spec/tasks/residents_notify_spec.rb' => %w[PacedDelivery ResidentMailer MailDeliveryFailure MailDelivery],
  'spec/jobs/recurring_job_spec.rb' => %w[RecurringJob RetryOnConflict Healthcheck JobRun],
  'spec/jobs/notify_cooks_job_spec.rb' => %w[NotifyCooksJob PacedDelivery MailDelivery],
  'spec/jobs/ensure_rotations_job_spec.rb' => %w[EnsureRotationsJob Community Rotation MealSchedule],
  'spec/serializers/api_contract_spec.rb' =>
    %w[MealSerializer BillSerializer GuestSerializer MealResidentSerializer EventSerializer
       GuestRoomReservationSerializer CommonHouseReservationSerializer RotationSerializer
       RotationLogSerializer ResidentBirthdaySerializer AuditSerializer ReconciliationPreviewSerializer],
  'spec/serializers/serializers_spec.rb' =>
    %w[MealSerializer BillSerializer GuestSerializer MealResidentSerializer EventSerializer
       GuestRoomReservationSerializer CommonHouseReservationSerializer RotationSerializer
       RotationLogSerializer ResidentBirthdaySerializer AuditSerializer AuditDescription
       ResidentNameShortener MealCostSummary],
  'spec/serializers/calendar_chip_contrast_spec.rb' => %w[RotationSerializer Rotation],
  'spec/serializers/calendar_chips_spec.rb' =>
    %w[MealSerializer BillSerializer EventSerializer GuestRoomReservationSerializer
       CommonHouseReservationSerializer ResidentBirthdaySerializer RotationSerializer],
  'spec/models/event_spec.rb' => %w[Event LiveUpdate BelongsToTheCommunity],
  'spec/models/common_house_reservation_spec.rb' => %w[CommonHouseReservation LiveUpdate BelongsToTheCommunity],
  'spec/models/guest_room_reservation_spec.rb' => %w[GuestRoomReservation LiveUpdate BelongsToTheCommunity],
  'spec/models/rotation_spec.rb' => %w[Rotation LiveUpdate BelongsToTheCommunity],
  'spec/models/meal_spec.rb' => %w[Meal LiveUpdate BelongsToTheCommunity],
  'spec/models/bill_spec.rb' =>
    %w[Bill LiveUpdate BelongsToTheCommunity LocksItsMealFirst ReconciledMealImmutability NotesMealLiveUpdate],
  'spec/models/meal_resident_spec.rb' =>
    %w[MealResident LiveUpdate BelongsToTheCommunity LocksItsMealFirst ReconciledMealImmutability
       ClosedMealAttendanceFreeze NotesMealLiveUpdate],
  'spec/models/guest_spec.rb' =>
    %w[Guest LiveUpdate LocksItsMealFirst ReconciledMealImmutability ClosedMealAttendanceFreeze NotesMealLiveUpdate],
  'spec/models/resident_spec.rb' => %w[Resident LiveUpdate BelongsToTheCommunity HasPhoneNumber],
  'spec/models/resident_price_band_spec.rb' => %w[Resident Community LiveUpdate BelongsToTheCommunity HasPhoneNumber],
  'spec/models/unit_spec.rb' => %w[Unit LiveUpdate BelongsToTheCommunity],
  'spec/requests/admin/all_pages_spec.rb' =>
    %w[BalanceDisplayHelper SettlementLinesTable MoneyFieldHelper ScheduleWeekLabelHelper PhoneDisplayHelper
       ApplicationHelper SuperuserAdapter],
  'spec/requests/admin/pages_with_data_spec.rb' =>
    %w[BalanceDisplayHelper SettlementLinesTable MoneyFieldHelper PhoneDisplayHelper ApplicationHelper
       MealCostSummary],
  'spec/models/community_dinner_start_times_spec.rb' => %w[Community],
  'spec/models/community_today_spec.rb' => %w[Community],
  'spec/models/community_today_outside_requests_spec.rb' => %w[Community],
  'spec/models/rotation_start_date_spec.rb' => %w[Rotation BelongsToTheCommunity],
  'spec/models/admin_user_spec.rb' => %w[AdminUser HasPhoneNumber],
  'spec/models/meal_charge_spec.rb' => %w[MealCharge AppendOnly],
  'spec/models/ledger_check_run_spec.rb' => %w[LedgerCheckRun AppendOnly],
  'spec/models/concerns/locks_its_meal_first_spec.rb' => %w[LocksItsMealFirst Bill],
  'spec/models/application_record_ransackable_attributes_spec.rb' => %w[ApplicationRecord],
  'spec/db/settled_meal_triggers_spec.rb' => %w[ReconciledMealImmutability],
  'spec/db/seeds_spec.rb' => %w[Community],
  'spec/lib/solid_cache/store_spec.rb' => [],

  # Slow or timing-dependent by design: a storm, random sequences, a
  # query-count budget, the thread-safety probes. Each takes seconds to
  # a minute, and none pins a line of the subjects above that a faster
  # spec does not. Never selected.
  'spec/concurrency/request_storm_spec.rb' => [],
  'spec/concurrency/recycled_thread_spec.rb' => [],
  'spec/concurrency/process_wide_state_spec.rb' => [],
  'spec/db/meal_write_storm_spec.rb' => [],
  'spec/requests/api/v1/meal_random_actions_spec.rb' => [],
  'spec/requests/api/v1/calendar_performance_spec.rb' => []
}.freeze

MUTANT_SPECS = MUTANT_SPEC_ROWS.to_h do |path, expressions|
  base = if path.start_with?('spec/requests/api/v1/')
           'ApiController'
         elsif path.start_with?('spec/requests/admin/')
           'ApplicationController'
         end
  [path, (expressions.empty? || base.nil? ? expressions : (expressions | [base])).freeze]
end.freeze

# Mutant runs the selected examples with --fail-fast, so a mutation is
# killed as soon as one example fails. The cheap, exact examples should
# come first: a unit spec on a service fails in a fraction of a second,
# a request spec or the race spec takes seconds to get to the same
# assertion. Ranked by directory; within a directory, by path and line.
MUTANT_DIRECTORY_ORDER = %w[
  spec/services spec/models spec/helpers spec/tasks spec/jobs
  spec/mailers spec/requests spec/db
].freeze

# The runtime type-check specs. Each one calls a method with the wrong
# type and expects the Sorbet sig to raise. Mutant cannot run them: it
# reinserts the method from its own copy of the source, without the
# `sig` block above it, so the unmutated code fails the example and every
# mutation "passes" it (2026-09-10: three Settlement and Reconciliation
# methods reported the unmutated code failing this way). An empty
# expression list keeps them out of every mutant run; the plain suite
# still runs them.
MUTANT_SIG_CHECK_SPECS = %w[
  spec/models/holidays_types_spec.rb
  spec/models/reconciliation_types_spec.rb
  spec/services/balance_recalculation_types_spec.rb
  spec/services/ledger_verification_types_spec.rb
  spec/services/meal_ledger_types_spec.rb
  spec/services/retry_on_conflict_types_spec.rb
  spec/services/settlement_types_spec.rb
].freeze
