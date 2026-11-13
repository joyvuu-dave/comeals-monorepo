-------------------------- MODULE SerializableOnly --------------------------
(***************************************************************************)
(* Challenge 2, option A: no locks we take ourselves. Every transaction    *)
(* must be SERIALIZABLE (a trigger refuses a write from any other          *)
(* isolation level), so PostgreSQL promises the same result as running     *)
(* the transactions one at a time, in some order (docs/models.md).        *)
(*                                                                         *)
(* That promise is the only thing this model assumes, so each transaction  *)
(* here is one step: the steps run one at a time, in every order. There is *)
(* no meal lock, no compare-and-swap that we wrote, and no trigger that    *)
(* writes the meal row.                                                    *)
(*                                                                         *)
(* What is left to choose is where the "is this dinner settled?" check     *)
(* lives:                                                                  *)
(*                                                                         *)
(*   - an app writer (the API, an admin form) checks it in the model's     *)
(*     validation before it writes;                                        *)
(*   - a psql writer runs no app code, so only a check in the database     *)
(*     can stop it. SettledCheckInDb is a trigger that reads the meal row  *)
(*     and refuses a write to a settled dinner. It only reads: under this  *)
(*     design a read is enough, because the database promises the order.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Settlers,          \* {"s1"} or {"s1", "s2"}
  AppWriters,        \* writers that run the app's checks
  PsqlWriters,       \* writers that run none
  SettledCheckInDb   \* BOOLEAN

None == "none"
Meals == {"m1", "m2"}
Writers == AppWriters \cup PsqlWriters
Txns == Settlers \cup Writers
NewRow(w) == "row_" \o w
Rows == {"r1"} \cup {NewRow(w) : w \in Writers}

VARIABLES rec, rowMeal, done, settled, claims
vars == <<rec, rowMeal, done, settled, claims>>

Init ==
  /\ rec = [m \in Meals |-> None]
  /\ rowMeal = [r \in Rows |-> IF r = "r1" THEN "m1" ELSE None]
  /\ done = {}
  /\ settled = {}
  /\ claims = 0

\* One settlement, as one serializable transaction: claim m1 if nobody
\* has, and charge its rows.
Settle(s) ==
  /\ s \notin done
  /\ done' = done \cup {s}
  /\ IF rec["m1"] = None
       THEN /\ rec' = [rec EXCEPT !["m1"] = s]
            /\ settled' = {r \in Rows : rowMeal[r] = "m1"}
            /\ claims' = claims + 1
       ELSE UNCHANGED <<rec, settled, claims>>
  /\ UNCHANGED rowMeal

\* A write is refused when a dinner it touches is settled and something
\* checks: the app's validation, or the database's trigger.
Refused(w, touched) ==
  /\ w \in AppWriters \/ SettledCheckInDb
  /\ \E m \in touched : rec[m] # None

\* One writer, as one serializable transaction: add a row to m1, remove
\* r1, or move r1 to m2.
WriteRow(w) ==
  /\ w \notin done
  /\ done' = done \cup {w}
  /\ \E change \in {"add", "remove", "move"} :
       LET row == IF change = "add" THEN NewRow(w) ELSE "r1"
           new == CASE change = "add" -> "m1" [] change = "remove" -> None [] change = "move" -> "m2"
           touched == ({rowMeal[row]} \cup {new}) \ {None}
       IN IF (change # "add" /\ rowMeal["r1"] = None) \/ Refused(w, touched)
            THEN UNCHANGED rowMeal
            ELSE rowMeal' = [rowMeal EXCEPT ![row] = new]
  /\ UNCHANGED <<rec, settled, claims>>

Next ==
  \/ \E s \in Settlers : Settle(s)
  \/ \E w \in Writers : WriteRow(w)
  \/ done = Txns /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

SettledRowsStay == claims > 0 => {r \in Rows : rowMeal[r] = "m1"} = settled
SettledOnce == claims <= 1
=============================================================================
