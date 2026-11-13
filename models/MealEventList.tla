--------------------------- MODULE MealEventList ---------------------------
(***************************************************************************)
(* Challenge 3: one numbered list of events per dinner, for any database   *)
(* Rails supports (docs/models.md).                                        *)
(*                                                                         *)
(*   meal_events(meal_id, position, kind, data, idempotency_key)           *)
(*   UNIQUE (meal_id, position)                                            *)
(*                                                                         *)
(* A write reads the dinner's events, decides, and inserts its event at    *)
(* the next position. A settlement is an event too: "settled, counting the *)
(* events before me". The design uses only what every database promises:  *)
(*                                                                         *)
(*   1. a transaction is all or nothing;                                   *)
(*   2. a unique index refuses a second row with the same key (at the      *)
(*      insert, or, on Galera, at commit).                                 *)
(*                                                                         *)
(* So the model assumes only those two. Every read is READ COMMITTED: it   *)
(* sees what was committed when it ran, and nothing stops another          *)
(* transaction from committing right after. Any transaction may abort at   *)
(* any step. A writer whose insert is refused reads again and tries once   *)
(* more, up to Attempts tries.                                             *)
(*                                                                         *)
(* UniquePositions switches the unique index off, to show that it is the   *)
(* piece that does the work.                                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Writers,          \* sign-ups and the like, e.g. {"w1", "w2"}
  Settlers,         \* {"s1"} or {"s1", "s2"}
  UniquePositions,  \* BOOLEAN
  Attempts          \* how many times a transaction may try

None == "none"
Txns == Writers \cup Settlers

VARIABLES
  events,  \* committed: a set of [pos, kind, by, upto]
  pc,      \* "read", "insert", "commit", "done"
  seen,    \* the last position a transaction read
  pending, \* the event a transaction is inserting, or None
  tries
vars == <<events, pc, seen, pending, tries>>

Last(es) == IF es = {} THEN 0 ELSE CHOOSE p \in {e.pos : e \in es} : \A e \in es : e.pos <= p
IsSettled(es) == \E e \in es : e.kind = "settled"

Init ==
  /\ events = {[pos |-> 1, kind |-> "signup", by |-> "seed", upto |-> 0]}
  /\ pc = [t \in Txns |-> "read"]
  /\ seen = [t \in Txns |-> 0]
  /\ pending = [t \in Txns |-> None]
  /\ tries = [t \in Txns |-> 1]

\* Read the dinner's events and decide. A writer refuses a settled dinner;
\* a settlement of a settled dinner does nothing.
Read(t) ==
  /\ pc[t] = "read"
  /\ seen' = [seen EXCEPT ![t] = Last(events)]
  /\ pc' = [pc EXCEPT ![t] = IF IsSettled(events) THEN "done" ELSE "insert"]
  /\ UNCHANGED <<events, pending, tries>>

Insert(t) ==
  /\ pc[t] = "insert"
  /\ pending' = [pending EXCEPT ![t] =
       [pos |-> seen[t] + 1, kind |-> IF t \in Settlers THEN "settled" ELSE "signup",
        by |-> t, upto |-> seen[t]]]
  /\ pc' = [pc EXCEPT ![t] = "commit"]
  /\ UNCHANGED <<events, seen, tries>>

\* The unique index: a position someone else committed first refuses this
\* insert. The writer reads again, if it has tries left.
Commit(t) ==
  /\ pc[t] = "commit"
  /\ IF UniquePositions /\ \E e \in events : e.pos = pending[t].pos
       THEN /\ pc' = [pc EXCEPT ![t] = IF tries[t] < Attempts THEN "read" ELSE "done"]
            /\ tries' = [tries EXCEPT ![t] = @ + 1]
            /\ UNCHANGED events
       ELSE /\ events' = events \cup {pending[t]}
            /\ pc' = [pc EXCEPT ![t] = "done"]
            /\ UNCHANGED tries
  /\ pending' = [pending EXCEPT ![t] = None]
  /\ UNCHANGED seen

Abort(t) ==
  /\ pc[t] \in {"insert", "commit"}
  /\ pc' = [pc EXCEPT ![t] = "done"]
  /\ pending' = [pending EXCEPT ![t] = None]
  /\ UNCHANGED <<events, seen, tries>>

Next ==
  \/ \E t \in Txns : Read(t) \/ Insert(t) \/ Commit(t) \/ Abort(t)
  \/ (\A t \in Txns : pc[t] = "done") /\ UNCHANGED vars

Spec == Init /\ [][Next]_vars

\* The settled event is the last event of its dinner, and it counts every
\* event before it: nothing was added at or after its position.
SettledIsLast ==
  \A s \in events : s.kind = "settled" =>
    /\ s.upto = s.pos - 1
    /\ \A e \in events : e # s => e.pos < s.pos

SettledOnce == Cardinality({e \in events : e.kind = "settled"}) <= 1
=============================================================================
