// What the Python made from these proofs runs (docs/proofs.md, "The Ruby
// against the proofs"). Each method takes the rows the Ruby has, in any
// order, and either refuses them or gives the one answer the rules allow.
//
// A proof only covers inputs that meet its `requires`. Dafny does not
// check a `requires` while the program runs, so the Python would give an
// answer that no proof covers to an input that breaks one. These methods
// check every such condition while running, and refuse an input that
// breaks one, so every answer they give is a proven one.
module EntryPoints {
  import opened Sums
  import opened TieOrder
  import LargestRemainderSplit
  import CentRounding
  import MealLines

  datatype Answer<T> = Refused | Answered(value: T)

  predicate NoneNegative(s: seq<int>)
  {
    forall i :: 0 <= i < |s| ==> s[i] >= 0
  }

  // The split. Refuses what LargestRemainderSplit.call refuses: a
  // negative total, a negative weight, or weights that sum to 0 (which
  // includes no weights at all).
  method Split(total: int, weights: seq<int>) returns (r: Answer<seq<int>>)
    ensures r.Refused? <==> total < 0 || !NoneNegative(weights) || Sum(weights) == 0
    ensures r.Answered? ==>
              && NoneNegative(weights)
              && Sum(weights) > 0
              && LargestRemainderSplit.IsSplit(total, weights, r.value)
  {
    if total < 0 || !NoneNegative(weights) || Sum(weights) == 0 {
      return Refused;
    }
    MealLines.SumOfNats(weights);
    var shares := LargestRemainderSplit.Split(total, weights);
    return Answered(shares);
  }

  // One resident's balance, in units.
  datatype Balance = Balance(id: int, units: int)

  function BalanceKey(b: Balance): seq<int>
  {
    [b.id]
  }

  function Units(s: seq<Balance>): seq<int>
  {
    seq(|s|, i requires 0 <= i < |s| => s[i].units)
  }

  function Ids(s: seq<Balance>): seq<int>
  {
    seq(|s|, i requires 0 <= i < |s| => s[i].id)
  }

  // The cent rounding, on balances in any order. They are put in order of
  // id first, since a tie goes to the lowest id. Refuses a cent that is
  // not above 0, two balances with one id, and balances that do not sum
  // to 0, which Settlement.allocate_to_cents refuses too.
  method Round(cent: int, rows: seq<Balance>) returns (r: Answer<seq<Balance>>, ghost sorted: seq<Balance>)
    ensures r.Answered? ==>
              && cent > 0
              && Keyed(rows, BalanceKey, 1)
              && multiset(sorted) == multiset(rows)
              && Sorted(sorted, BalanceKey)
              && Sum(Units(sorted)) == 0
              && Ids(r.value) == Ids(sorted)
              && CentRounding.IsRounding(cent, Units(sorted), Units(r.value))
  {
    sorted := [];
    if cent <= 0 || !Keyed(rows, BalanceKey, 1) {
      return Refused, sorted;
    }
    var ordered := Sort(rows, BalanceKey, 1);
    sorted := ordered;
    if Sum(Units(ordered)) != 0 {
      return Refused, sorted;
    }
    var out := CentRounding.Round(cent, Units(ordered));
    var rounded := seq(|ordered|, i requires 0 <= i < |ordered| && |out| == |ordered| => Balance(ordered[i].id, out[i]));
    assert Units(rounded) == out;
    return Answered(rounded), sorted;
  }

  // One cook's bill, and one person who ate: an attendee, or a guest
  // charged to the resident who brought them.
  datatype Cook = Cook(residentId: int, spent: int, noCost: bool)
  datatype Eater = Eater(residentId: int, guest: bool, rowId: int, multiplier: int)

  // One bill per cook, so the resident id is the whole order.
  function CookKey(c: Cook): seq<int>
  {
    [c.residentId]
  }

  // Lowest resident id, then an attendee before a guest, then the lower
  // row id (two guests of one host).
  function EaterKey(e: Eater): seq<int>
  {
    [e.residentId, if e.guest then 1 else 0, e.rowId]
  }

  // A bill marked No cost makes no line (MealLines.dfy, rule 1).
  function Paid(s: seq<Cook>): seq<Cook>
  {
    if |s| == 0 then [] else (if s[0].noCost then [] else [s[0]]) + Paid(s[1..])
  }

  function Spent(s: seq<Cook>): seq<int>
  {
    seq(|s|, i requires 0 <= i < |s| => s[i].spent)
  }

  function Multipliers(s: seq<Eater>): seq<int>
  {
    seq(|s|, i requires 0 <= i < |s| => s[i].multiplier)
  }

  // The cooks and the eaters in tie-break order, with each one's credit or
  // charge in the same position.
  datatype Lines = Lines(cooks: seq<Cook>, credits: seq<int>, eaters: seq<Eater>, charges: seq<int>)

  function DinnerOf(cooks: seq<Cook>, eaters: seq<Eater>, hasCap: bool, cap: int, cancelled: bool): MealLines.Dinner
    requires NoneNegative(Spent(cooks)) && NoneNegative(Multipliers(eaters)) && cap >= 0
  {
    MealLines.Dinner(Spent(cooks), Multipliers(eaters), if hasCap then MealLines.CapPerUnit(cap) else MealLines.NoCap,
                     cancelled)
  }

  // The lines of one dinner, on its bills and eaters in any order.
  // Refuses two bills of one cook, two eaters with one key, an amount,
  // multiplier or cap below 0. The database refuses all of those.
  method Dinner(cooks: seq<Cook>, eaters: seq<Eater>, hasCap: bool, cap: int, cancelled: bool)
    returns (r: Answer<Lines>)
    ensures r.Answered? ==>
              && Keyed(Paid(cooks), CookKey, 1)
              && Keyed(eaters, EaterKey, 3)
              && multiset(r.value.cooks) == multiset(Paid(cooks))
              && Sorted(r.value.cooks, CookKey)
              && multiset(r.value.eaters) == multiset(eaters)
              && Sorted(r.value.eaters, EaterKey)
              && NoneNegative(Spent(r.value.cooks))
              && NoneNegative(Multipliers(r.value.eaters))
              && cap >= 0
              && MealLines.IsLines(DinnerOf(r.value.cooks, r.value.eaters, hasCap, cap, cancelled),
                                   r.value.credits, r.value.charges)
  {
    var paid := Paid(cooks);
    if !Keyed(paid, CookKey, 1) || !Keyed(eaters, EaterKey, 3) || cap < 0 {
      return Refused;
    }
    var sortedCooks := Sort(paid, CookKey, 1);
    var sortedEaters := Sort(eaters, EaterKey, 3);
    if !NoneNegative(Spent(sortedCooks)) || !NoneNegative(Multipliers(sortedEaters)) {
      return Refused;
    }
    var credits, charges := MealLines.Lines(DinnerOf(sortedCooks, sortedEaters, hasCap, cap, cancelled));
    return Answered(Lines(sortedCooks, credits, sortedEaters, charges));
  }
}
