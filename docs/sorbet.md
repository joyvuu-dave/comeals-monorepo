# Sorbet

Sorbet is the static type checker for the Ruby side. `bin/check` runs it
(`bundle exec srb tc`) and fails on any error. This page says what is
checked, what is not, and how to work with it.

## What runs where

| Piece                | Runs when                                                     | What it does                                                                                                                       |
| -------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `bundle exec srb tc` | `bin/check`, or by hand                                       | Type checks every file with a `# typed:` sigil above `false`. Takes under a second.                                                |
| `bin/tapioca gem`    | after a gem changes version                                   | Rewrites `sorbet/rbi/gems/`: what Sorbet knows about each gem.                                                                     |
| `bin/tapioca dsl`    | after a migration, a new model, or a new association or scope | Rewrites `sorbet/rbi/dsl/`: the methods Rails writes at boot (column readers, associations, scopes, route helpers). Boots the app. |
| `sorbet-runtime`     | in every process                                              | Provides `T.must`, `T.let`, `T.bind` and `sig`.                                                                                    |

`bin/check` also runs both tapioca commands with `--verify` and fails when
an RBI file is stale. A stale RBI hides errors: a renamed column keeps its
old reader in the RBI, and Sorbet accepts calls to it.

## Which files are typed

Every Ruby file carries a sigil on line 1.

| Sigil            | Where                                                                                                               | Why                                                                                                                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `# typed: true`  | `app/models`, `app/services`, `app/serializers`, `app/controllers`, `app/jobs`, `app/mailers`, `app/helpers`, `lib` | The code that computes money and serves requests. Sorbet reports a method that does not exist, a call on a value that can be nil, and a wrong argument count.                                  |
| `# typed: false` | `app/models/concerns`, `app/admin`, `config`, `db`                                                                  | Sorbet only checks syntax and that constants resolve. Concerns: see below. Admin: the ActiveAdmin DSL runs blocks with a `self` Sorbet cannot see. Config and db: DSL files and migrations.    |
| none             | `spec`                                                                                                              | Sorbet ignores `spec/` (`sorbet/config`). A `def` inside an RSpec block is a method on `Object` to Sorbet, so the 125 helpers defined inside describe blocks would leak into every typed file. |

No file has `# typed: strict` yet. `strict` requires a `sig` on every
method. The plan is to add sigs to the money path first (`MealLedger`,
`Settlement`, `BalanceRecalculation`, `LedgerVerification`,
`MealCharge`) and move those files to `strict` one at a time, once each
one has sigs that pass the test suite.

## How column and association types are generated

Tapioca writes the column readers as `T.nilable` for every column, NOT
NULL or not (`ActiveRecordColumnTypes: nilable` in
`sorbet/tapioca/config.yml`). The default setting, `persisted`, types a
NOT NULL column as never nil. That is true after a save and false before
one, and validations and `before_validation` callbacks run before one. With
`persisted`, Sorbet marked the nil guards in `Reconciliation`,
`CommonHouseReservation` and `Event` validations as unreachable code. A
reader who trusted that would delete a guard that is needed.

The cost of `nilable` is `T.must` on reads of NOT NULL columns outside
validations: `T.must(finished_at) - T.must(started_at)`. `T.must` raises
`TypeError` if the value is nil, which is where the old code raised
`NoMethodError` a line later. The record's shape is the same; the failure
is now named.

`belongs_to` readers are always `T.nilable` in this Tapioca version, even
when the foreign key is NOT NULL. So `T.must(community)` and
`T.must(bill.meal)` appear where the model reads its parent. The
`community_id` column is NOT NULL on every table and
`BelongsToTheCommunity` fills it before validation, so that `T.must` cannot
fire on a saved record.

## Patterns Sorbet asks for

**Read a nilable attribute into a local before testing it.** Sorbet narrows
a local variable after `nil?`; it does not narrow a method call, because
the next call could return something else.

```ruby
# Sorbet: `<` does not exist on NilClass
return if end_date.blank?
return if end_date < community.today

# Fine
end_date = self.end_date
return if end_date.nil?
return if end_date < T.must(community).today
```

**`blank?` and `present?` do not narrow.** Use `nil?` on a local when the
value is a record, a date, or a number, where blank means nil. Keep
`blank?` for strings and add `T.must` after it.

**Name `self` inside a class-level DSL block.** Alba's `attribute :x do
|record| ... end` runs the block on the serializer instance, but Sorbet sees
a block at class level. The first line of such a block is
`T.bind(self, TheSerializer)`. The same is true of a `validates ... if:`
lambda: give it the record as an argument, `->(resident) { ... }`, instead
of calling instance methods on an implicit self.

**A variable assigned inside a block needs its type declared outside.**
`rotation = T.let(nil, T.nilable(Rotation))` before `find_each`. Better,
when the block runs once, return the value from the block:
`meals, ids = SnapshotRead.call do ... [meals, ids] end`.

**A helper module that uses view helpers says so.** `extend T::Helpers`
and `requires_ancestor { ActionView::Base }` at the top of the module
resolve `tag`, `number_to_currency` and friends. This needs
`--enable-experimental-requires-ancestor` in `sorbet/config`.

**A method Sorbet cannot see gets a shim, not `T.unsafe`.** Devise writes
`authenticate_admin_user!` at boot and Icalendar builds `x_wr_calname=`
with `method_missing`. Both are declared by hand in `sorbet/rbi/shims/`.
Keep a shim next to a comment saying which gem call defines the method,
so it can be removed when Tapioca learns to generate it.

## Concerns stay at `typed: false` for now

A concern calls methods that only exist on the model that includes it:
`meal`, `phone`, `meal_id_in_database`, `errors`, `throw`. Sorbet checks
the module on its own and finds none of them. The fix is an interface
module that declares the methods the concern needs (`sig { abstract
.returns(Meal) }` for `meal`) and `requires_ancestor`. Two of the seven
concerns hold money-path rules (`ClosedMealAttendanceFreeze`,
`ReconciledMealImmutability`), so this is worth doing, but as its own
change.

## Runtime behaviour

`sorbet-runtime` checks a `sig` when the method is called. By default a
value that does not match raises `TypeError`, in production too.
`config/initializers/sorbet.rb` changes that outside the test suite: a
failed check is reported through `Rails.error` to Bugsnag and the call
goes on. In the test suite it raises, so a wrong sig fails a spec, and in
production it shows up as a Bugsnag report instead of a 500.

The setting `T::Configuration.default_checked_level = :tests` would skip
the checks in production instead of reporting them. It is not used because
it must be set before any sig is evaluated, and `bin/tapioca dsl`, which
is itself written with Sorbet, has evaluated sigs long before it loads the
app's initializers. It refuses to boot the app with that setting in place.

`T.must`, `T.let` and `T.cast` are not sigs. They always raise.

## Gotchas found during setup

- **net-imap** ships an RBI that redefines two superclasses Sorbet's
  built-in stdlib RBI already declares. Nothing here uses IMAP (`mail`
  depends on it), so `sorbet/tapioca/config.yml` excludes the gem.
- **Tapioca's `todo.rbi`** lists constants it could not resolve. After
  `bin/tapioca dsl` it must be regenerated with `bin/tapioca todo`, or it
  redeclares as a module a constant the DSL RBIs define as a class.
- **`render ... and return`** does not tell Sorbet the method ends. Write
  `return render(...)` so the nil check before it narrows the variable.
- **`sum(&:amount)` over nilable columns** returns a nilable to Sorbet.
  Use a block with `T.must`.
