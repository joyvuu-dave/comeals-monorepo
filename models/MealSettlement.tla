--------------------------- MODULE MealSettlement ---------------------------
(***************************************************************************)
(* The protocol that keeps a settled dinner's rows from changing           *)
(* (ADR 0003, challenge 28, docs/models.md).                               *)
(*                                                                         *)
(* One settlement (or two at once) settles dinner m1. Beside it, writers   *)
(* change m1's rows (an attendance row stands for every child row: bills,  *)
(* attendance, guests):                                                    *)
(*                                                                         *)
(*   - the API, at SERIALIZABLE, under with_meal_lock (FOR UPDATE on the   *)
(*     meal row), adds a row or removes one;                               *)
(*   - an admin form, at SERIALIZABLE, under LocksItsMealFirst (FOR KEY    *)
(*     SHARE on each meal it touches, in id order), adds, removes, or      *)
(*     moves a row to dinner m2;                                           *)
(*   - psql, at READ COMMITTED, with no lock of its own, does the same.    *)
(*                                                                         *)
(* Three pieces, each one a switch:                                        *)
(*                                                                         *)
(*   SettleLocks       Settlement#assign_meals takes FOR UPDATE on the     *)
(*                     meals before it claims them.                        *)
(*   ClaimIfUnclaimed  the claim is a compare-and-swap: UPDATE ... WHERE   *)
(*                     reconciliation_id IS NULL, and a count short of the *)
(*                     meals means another settlement got there first.     *)
(*   Trigger           comeals_reject_settled_child_write. "update" is     *)
(*                     today's: it updates the meal row (FOR NO KEY UPDATE)*)
(*                     and refuses if the meal is settled. "keyshare" is   *)
(*                     the one from 2026-07-27 to 2026-10-16: it read the  *)
(*                     meal row FOR KEY SHARE. "none" is no trigger.       *)
(*   TriggerOld        the trigger looks up OLD.meal_id as well as         *)
(*                     NEW.meal_id. Without it a delete looks up nothing,  *)
(*                     and a move looks up only the dinner the row goes to.*)
(*                                                                         *)
(* What PostgreSQL does, as modelled here:                                 *)
(*                                                                         *)
(*   - Row locks: FOR UPDATE ("U"), FOR NO KEY UPDATE ("NKU", which an     *)
(*     UPDATE of a column that is not a key takes) and FOR KEY SHARE       *)
(*     ("KS", which an insert's foreign key check takes on the parent      *)
(*     row). A step that needs a lock another transaction holds in a mode  *)
(*     that conflicts with it waits: the step is not enabled.              *)
(*   - A SERIALIZABLE transaction reads from the snapshot taken at its     *)
(*     first statement. When it locks or updates a row that a transaction *)
(*     committed after that snapshot, it fails ("could not serialize       *)
(*     access due to concurrent update").                                  *)
(*   - A READ COMMITTED statement reads the newest committed rows. When    *)
(*     its UPDATE or DELETE waited for a row lock, it works on the newest  *)
(*     version of the row once it has the lock (EvalPlanQual).            *)
(*                                                                         *)
(* What is left out, on purpose, so that a property that holds here holds  *)
(* in PostgreSQL too:                                                      *)
(*                                                                         *)
(*   - Every transaction may abort at any step (Abort). That covers a      *)
(*     deadlock, a lock timeout, a statement timeout, a crash, and SSI.    *)
(*     An abort writes nothing, so allowing more of them can only show     *)
(*     more orders, never hide one.                                        *)
(*   - SSI's own checks (rw-conflicts between SERIALIZABLE transactions)   *)
(*     are not modelled. They only abort transactions, which Abort         *)
(*     already allows; leaving them out lets more transactions commit.     *)
(*   - FOR KEY SHARE at SERIALIZABLE never fails here, even on a row       *)
(*     another transaction changed. PostgreSQL may fail it; never failing  *)
(*     lets more transactions commit.                                      *)
(*                                                                         *)
(* So when this model says a property holds, it holds for every order of   *)
(* these steps that PostgreSQL allows. When it says a property fails, the  *)
(* trace it prints must be read: it is real only if PostgreSQL would not   *)
(* have aborted one of its transactions for a reason this model leaves out.*)
(* docs/models.md says which traces were checked that way.                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Settlers,          \* settlement transactions, {"s1"} or {"s1", "s2"}
  ApiWriters,        \* {"api"} or {}
  AdminWriters,      \* {"admin"} or {}
  PsqlWriters,       \* {"psql"} or {}
  SettleLocks,       \* BOOLEAN
  ClaimIfUnclaimed,  \* BOOLEAN
  Trigger,           \* "update", "keyshare" or "none"
  TriggerOld,        \* BOOLEAN
  SettleReadCommitted \* BOOLEAN: the settlement runs at READ COMMITTED, not SERIALIZABLE

None == "none"
Unset == "unset"
Meals == {"m1", "m2"}
Writers == ApiWriters \cup AdminWriters \cup PsqlWriters
Txns == Settlers \cup Writers

\* Each writer adds a row of its own, so two adds never meet on a key.
NewRow(w) == "row_" \o w
Rows == {"r1"} \cup {NewRow(w) : w \in Writers}
Objs == Meals \cup Rows

\* What each kind of writer can do.
OpsOf(w) == IF w \in ApiWriters THEN {"add", "remove"} ELSE {"add", "remove", "move"}

Iso(t) == IF t \in PsqlWriters \/ (t \in Settlers /\ SettleReadCommitted)
            THEN "read committed" ELSE "serializable"

\* Pairs of lock modes that conflict (PostgreSQL's row lock table).
Conflict == {<<"U", "U">>, <<"U", "NKU">>, <<"U", "KS">>,
             <<"NKU", "U">>, <<"NKU", "NKU">>, <<"KS", "U">>}

VARIABLES
  rec,       \* committed: meal -> the settlement that claimed it, or None
  rowMeal,   \* committed: row -> its meal, or None when it does not exist
  lastTs,    \* object -> the commit counter of the last commit that wrote it
  clock,     \* the commit counter
  pc,        \* transaction -> where it is
  op,        \* writer -> what it does
  snapRec, snapRow, snapTs,  \* each transaction's snapshot
  wRec, wRow,  \* each transaction's writes, not yet committed
  locks,     \* transaction -> set of <<object, mode>>
  trig,      \* writer -> the meals its trigger still has to look up
  counted,   \* settlement -> the rows of m1 it charged
  settled,   \* the rows of m1 the committed settlement charged
  claims     \* how many committed settlements claimed m1

vars == <<rec, rowMeal, lastTs, clock, pc, op, snapRec, snapRow, snapTs, wRec, wRow,
          locks, trig, counted, settled, claims>>

Init ==
  /\ rec = [m \in Meals |-> None]
  /\ rowMeal = [r \in Rows |-> IF r = "r1" THEN "m1" ELSE None]
  /\ lastTs = [o \in Objs |-> 0]
  /\ clock = 0
  /\ pc = [t \in Txns |-> "start"]
  /\ op = [t \in Txns |-> None]
  /\ snapRec = [t \in Txns |-> [m \in Meals |-> None]]
  /\ snapRow = [t \in Txns |-> [r \in Rows |-> None]]
  /\ snapTs = [t \in Txns |-> 0]
  /\ wRec = [t \in Txns |-> [m \in Meals |-> Unset]]
  /\ wRow = [t \in Txns |-> [r \in Rows |-> Unset]]
  /\ locks = [t \in Txns |-> {}]
  /\ trig = [t \in Txns |-> <<>>]
  /\ counted = [t \in Txns |-> {}]
  /\ settled = {}
  /\ claims = 0

----------------------------------------------------------------------------
(* Reads, locks and the serialization check *)

\* What t reads: its own write, else its snapshot (SERIALIZABLE) or the
\* newest committed value (READ COMMITTED).
RecFor(t, m) == IF wRec[t][m] # Unset THEN wRec[t][m]
                ELSE IF Iso(t) = "serializable" THEN snapRec[t][m] ELSE rec[m]
RowFor(t, r) == IF wRow[t][r] # Unset THEN wRow[t][r]
                ELSE IF Iso(t) = "serializable" THEN snapRow[t][r] ELSE rowMeal[r]

\* A SERIALIZABLE transaction that locks or updates this object now fails.
ChangedSinceSnapshot(t, o) == Iso(t) = "serializable" /\ lastTs[o] > snapTs[t]

Free(t, o, mode) == \A u \in Txns \ {t} : \A l \in locks[u] : l[1] = o => <<mode, l[2]>> \notin Conflict
Take(t, o, mode) == locks' = [locks EXCEPT ![t] = @ \cup {<<o, mode>>}]

Active(t) == pc[t] \notin {"start", "committed", "aborted"}

\* Ends t with nothing written: a refusal, a failed check, or any abort.
End(t) ==
  /\ pc' = [pc EXCEPT ![t] = "aborted"]
  /\ locks' = [locks EXCEPT ![t] = {}]
  /\ trig' = [trig EXCEPT ![t] = <<>>]

Abort(t) ==
  /\ Active(t)
  /\ End(t)
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, wRow,
                 counted, settled, claims>>

Commit(t) ==
  /\ pc[t] = "commit"
  /\ LET written == {m \in Meals : wRec[t][m] # Unset} \cup {r \in Rows : wRow[t][r] # Unset}
     IN /\ rec' = [m \in Meals |-> IF wRec[t][m] # Unset THEN wRec[t][m] ELSE rec[m]]
        /\ rowMeal' = [r \in Rows |-> IF wRow[t][r] # Unset THEN wRow[t][r] ELSE rowMeal[r]]
        /\ lastTs' = [o \in Objs |-> IF o \in written THEN clock + 1 ELSE lastTs[o]]
  /\ clock' = clock + 1
  /\ pc' = [pc EXCEPT ![t] = "committed"]
  /\ locks' = [locks EXCEPT ![t] = {}]
  /\ IF t \in Settlers
       THEN /\ settled' = counted[t]
            /\ claims' = claims + 1
       ELSE UNCHANGED <<settled, claims>>
  /\ UNCHANGED <<op, snapRec, snapRow, snapTs, wRec, wRow, trig, counted>>

\* The first statement of a SERIALIZABLE transaction takes its snapshot.
TakeSnapshot(t) ==
  /\ snapRec' = [snapRec EXCEPT ![t] = rec]
  /\ snapRow' = [snapRow EXCEPT ![t] = rowMeal]
  /\ snapTs' = [snapTs EXCEPT ![t] = clock]

----------------------------------------------------------------------------
(* A settlement: Settle.settle! and Settlement#assign_meals *)

\* eligible_meal_ids: m1 when it is not claimed yet. Else nothing to settle.
SBegin(s) ==
  /\ pc[s] = "start"
  /\ TakeSnapshot(s)
  /\ pc' = [pc EXCEPT ![s] = IF rec["m1"] # None THEN "aborted"
                             ELSE IF SettleLocks THEN "lock" ELSE "claim"]
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, wRec, wRow, locks, trig, counted, settled, claims>>

\* Meal.where(id: meal_ids).order(:id).lock
SLock(s) ==
  /\ pc[s] = "lock"
  /\ Free(s, "m1", "U")
  /\ IF ChangedSinceSnapshot(s, "m1")
       THEN End(s) /\ UNCHANGED <<snapRec, snapRow, snapTs, wRec>>
       ELSE Take(s, "m1", "U") /\ pc' = [pc EXCEPT ![s] = "claim"] /\ UNCHANGED trig
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, wRow, counted, settled, claims>>

\* UPDATE meals SET reconciliation_id = s WHERE id = m1 [AND reconciliation_id IS NULL]
SClaim(s) ==
  /\ pc[s] = "claim"
  /\ Free(s, "m1", "NKU")
  /\ LET current == IF Iso(s) = "serializable" THEN RecFor(s, "m1") ELSE rec["m1"]
     IN IF ChangedSinceSnapshot(s, "m1") \/ (ClaimIfUnclaimed /\ current # None)
          THEN End(s) /\ UNCHANGED wRec
          ELSE /\ wRec' = [wRec EXCEPT ![s]["m1"] = s]
               /\ Take(s, "m1", "NKU")
               /\ pc' = [pc EXCEPT ![s] = "read"]
               /\ UNCHANGED trig
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRow, counted, settled, claims>>

\* write_ledger!: the rows of m1 it charges.
SRead(s) ==
  /\ pc[s] = "read"
  /\ counted' = [counted EXCEPT ![s] = {r \in Rows : RowFor(s, r) = "m1"}]
  /\ pc' = [pc EXCEPT ![s] = "commit"]
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, wRow, locks, trig,
                 settled, claims>>

----------------------------------------------------------------------------
(* A writer *)

WBegin(w) ==
  /\ pc[w] = "start"
  /\ \E o \in OpsOf(w) :
       /\ op' = [op EXCEPT ![w] = o]
       /\ TakeSnapshot(w)
       /\ pc' = [pc EXCEPT ![w] = IF w \in ApiWriters THEN "api lock"
                                  ELSE IF w \in AdminWriters THEN "admin lock" ELSE "write"]
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, wRec, wRow, locks, trig, counted, settled, claims>>

\* with_meal_lock: FOR UPDATE on the meal, then the settled check.
ApiLock(w) ==
  /\ pc[w] = "api lock"
  /\ Free(w, "m1", "U")
  /\ IF ChangedSinceSnapshot(w, "m1") \/ RecFor(w, "m1") # None
       THEN End(w)
       ELSE Take(w, "m1", "U") /\ pc' = [pc EXCEPT ![w] = "write"] /\ UNCHANGED trig
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, wRow, counted, settled, claims>>

\* The meals LocksItsMealFirst locks: the row's meal as loaded, and the
\* meal it moves to.
AdminMeals(w) ==
  CASE op[w] = "add" -> {"m1"}
    [] op[w] = "remove" -> {RowFor(w, "r1")} \ {None}
    [] op[w] = "move" -> ({RowFor(w, "r1")} \ {None}) \cup {"m2"}

\* LocksItsMealFirst, one meal at a time in id order ("m1" < "m2"), then
\* ReconciledMealImmutability's check, read from the snapshot. A row the
\* form loaded that is gone answers 404.
AdminLock(w) ==
  /\ pc[w] = "admin lock"
  /\ LET todo == {m \in AdminMeals(w) : <<m, "KS">> \notin locks[w]}
     IN IF todo = {}
          THEN /\ IF (op[w] # "add" /\ RowFor(w, "r1") = None) \/ (\E m \in AdminMeals(w) : RecFor(w, m) # None)
                    THEN End(w)
                    ELSE pc' = [pc EXCEPT ![w] = "write"] /\ UNCHANGED <<locks, trig>>
          ELSE LET m == CHOOSE x \in todo : \A y \in todo : x = y \/ x = "m1"
               IN /\ Free(w, m, "KS")
                  /\ Take(w, m, "KS")
                  /\ UNCHANGED <<pc, trig>>
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, wRow, counted, settled, claims>>

\* The meals the trigger looks up for a row that was in `old` and is now in `new`.
TriggerMeals(old, new) ==
  IF Trigger = "none" THEN <<>>
  ELSE (IF TriggerOld /\ old # None THEN <<old>> ELSE <<>>) \o (IF new # None THEN <<new>> ELSE <<>>)

\* The row write. An add takes FOR KEY SHARE on its meal (the foreign
\* key check). A remove or a move locks the row and, at READ COMMITTED,
\* works on its newest version; a row that is gone by then is 0 rows.
Write(w) ==
  /\ pc[w] = "write"
  /\ CASE op[w] = "add" ->
            /\ Free(w, "m1", "KS")
            /\ Take(w, "m1", "KS")
            /\ wRow' = [wRow EXCEPT ![w][NewRow(w)] = "m1"]
            /\ trig' = [trig EXCEPT ![w] = TriggerMeals(None, "m1")]
            /\ pc' = [pc EXCEPT ![w] = "trigger"]
       [] op[w] \in {"remove", "move"} ->
            LET old == RowFor(w, "r1")
                new == IF op[w] = "move" THEN "m2" ELSE None
            IN /\ Free(w, "r1", "U")
               /\ op[w] = "move" => Free(w, "m2", "KS")
               /\ IF ChangedSinceSnapshot(w, "r1")
                    THEN End(w) /\ UNCHANGED wRow
                    ELSE IF old = None
                      THEN pc' = [pc EXCEPT ![w] = "commit"] /\ UNCHANGED <<locks, trig, wRow>>
                      ELSE /\ locks' = [locks EXCEPT ![w] = @ \cup {<<"r1", "U">>}
                                          \cup (IF op[w] = "move" THEN {<<"m2", "KS">>} ELSE {})]
                           /\ wRow' = [wRow EXCEPT ![w]["r1"] = new]
                           /\ trig' = [trig EXCEPT ![w] = TriggerMeals(old, new)]
                           /\ pc' = [pc EXCEPT ![w] = "trigger"]
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRec, counted, settled, claims>>

\* comeals_reject_settled_child_write, one meal lookup per step.
TriggerStep(w) ==
  /\ pc[w] = "trigger"
  /\ IF trig[w] = <<>>
       THEN pc' = [pc EXCEPT ![w] = "commit"] /\ UNCHANGED <<locks, trig, wRec>>
       ELSE LET m == Head(trig[w])
                mode == IF Trigger = "update" THEN "NKU" ELSE "KS"
                current == RecFor(w, m)
            IN /\ Free(w, m, mode)
               /\ IF (Trigger = "update" /\ ChangedSinceSnapshot(w, m)) \/ current # None
                    THEN End(w) /\ UNCHANGED wRec
                    ELSE /\ Take(w, m, mode)
                         /\ trig' = [trig EXCEPT ![w] = Tail(@)]
                         \* UPDATE meals SET updated_at = updated_at: a write of the meal row
                         /\ IF Trigger = "update"
                              THEN wRec' = [wRec EXCEPT ![w][m] = current]
                              ELSE UNCHANGED wRec
                         /\ UNCHANGED pc
  /\ UNCHANGED <<rec, rowMeal, lastTs, clock, op, snapRec, snapRow, snapTs, wRow, counted, settled, claims>>

----------------------------------------------------------------------------

Next ==
  \/ \E s \in Settlers : SBegin(s) \/ SLock(s) \/ SClaim(s) \/ SRead(s)
  \/ \E w \in Writers : WBegin(w) \/ ApiLock(w) \/ AdminLock(w) \/ Write(w) \/ TriggerStep(w)
  \/ \E t \in Txns : Commit(t) \/ Abort(t)
  \/ (\A t \in Txns : pc[t] \in {"committed", "aborted"}) /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* The properties *)

\* A settled dinner's rows are the rows its settlement charged, from the
\* moment it commits on: no row added, removed or moved away after.
SettledRowsStay == claims > 0 => {r \in Rows : rowMeal[r] = "m1"} = settled

\* A dinner is settled once.
SettledOnce == claims <= 1

TypeOK ==
  /\ rec \in [Meals -> Settlers \cup {None}]
  /\ rowMeal \in [Rows -> Meals \cup {None}]
  /\ claims \in 0..2
=============================================================================
