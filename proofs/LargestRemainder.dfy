// The part the split and the cent rounding share: hand out k units, one
// each, to the entries with the largest key, ties to the earlier
// position. Only entries with a key above zero may get one.
//
// For the split (LargestRemainderSplit.dfy) the key is what each share
// dropped when it was rounded down, and the units are the ones left
// over. For the cent rounding (CentRounding.dfy) the key is how much
// each balance lost when it was cut to a whole cent, on the side the
// cents move, and the units are the leftover cents.
//
// This file proves that the units can always be handed out
// (CountFits, HandOut), and that only one way of handing them out
// follows the order (OnlyOneHandOut).
module LargestRemainder {
  import opened Sums
  import opened Arithmetic

  // 1 for an entry whose key is above zero, 0 for one whose key is not.
  function Positive(key: seq<int>): seq<int>
  {
    seq(|key|, i requires 0 <= i < |key| => if key[i] > 0 then 1 else 0)
  }

  // Entry i comes before entry j: its key is larger, or the same and it
  // is earlier.
  predicate Before(key: seq<int>, i: int, j: int)
    requires 0 <= i < |key| && 0 <= j < |key|
  {
    key[i] > key[j] || (key[i] == key[j] && i < j)
  }

  // got is a way of handing out units by the order: one unit at most per
  // entry, only to entries whose key is above zero, and every entry that
  // got one comes before every entry that did not.
  predicate HandedOut(key: seq<int>, got: seq<int>)
  {
    && |got| == |key|
    && (forall i :: 0 <= i < |got| ==> got[i] == 0 || got[i] == 1)
    && (forall i :: 0 <= i < |got| && got[i] == 1 ==> key[i] > 0)
    && (forall i, j :: 0 <= i < |got| && 0 <= j < |got| && got[i] == 1 && got[j] == 0 ==> Before(key, i, j))
  }

  // If every key is below `bound` and the keys add up to bound * k, then
  // there are at least k keys above zero. This is why there is always an
  // entry to give each unit to.
  lemma CountFits(key: seq<int>, bound: int, k: int)
    requires bound > 0
    requires forall i :: 0 <= i < |key| ==> key[i] < bound
    requires Sum(key) == bound * k
    ensures k <= Sum(Positive(key))
  {
    var n := |key|;
    var positive := Positive(key);
    var count := Sum(positive);

    var most := seq(n, i requires 0 <= i < n => (bound - 1) * positive[i]);
    SumOfMultiples(positive, bound - 1, most);
    forall i | 0 <= i < n
      ensures key[i] <= most[i]
    {
      if key[i] > 0 {
        assert positive[i] == 1 && most[i] == bound - 1;
      } else {
        assert positive[i] == 0 && most[i] == 0;
      }
    }
    SumNoLarger(key, most);

    var zeros := seq(n, i requires 0 <= i < n => 0);
    SumOfMultiples(positive, 0, zeros);
    SumNoLarger(zeros, positive);

    assert bound * k <= (bound - 1) * count;
    assert count >= 0;

    // bound * k <= (bound - 1) * count < bound * (count + 1).
    if k > count {
      MulKeepsOrder(bound, count + 1, k);
      MulOneMore(count, bound);
      assert bound * k >= bound * count + bound;
      MulOneLess(bound, count);
      assert (bound - 1) * count == bound * count - count;
      assert false;
    }
  }

  // If fewer units are out than there are keys above zero, and every unit
  // went to a key above zero, an entry with a key above zero is waiting.
  lemma SomeEntryWaits(got: seq<int>, key: seq<int>)
    requires |got| == |key|
    requires forall i :: 0 <= i < |got| ==> got[i] == 0 || got[i] == 1
    requires forall i :: 0 <= i < |got| && got[i] == 1 ==> key[i] > 0
    requires Sum(got) < Sum(Positive(key))
    ensures exists u :: 0 <= u < |got| && got[u] == 0 && key[u] > 0
  {
    if forall u :: 0 <= u < |got| && got[u] == 0 ==> key[u] <= 0 {
      SumNoLarger(Positive(key), got);
    }
  }

  // The entry that comes first, among those that have not got a unit.
  method First(got: seq<int>, key: seq<int>) returns (best: int)
    requires |got| == |key|
    requires exists u :: 0 <= u < |got| && got[u] == 0
    ensures 0 <= best < |got| && got[best] == 0
    ensures forall j :: 0 <= j < |got| && got[j] == 0 && j != best ==> Before(key, best, j)
  {
    best := -1;
    var i := 0;
    while i < |got|
      invariant 0 <= i <= |got|
      invariant best == -1 ==> forall j :: 0 <= j < i ==> got[j] != 0
      invariant best != -1 ==> 0 <= best < i && got[best] == 0
      invariant best != -1 ==> forall j :: 0 <= j < i && got[j] == 0 && j != best ==> Before(key, best, j)
    {
      if got[i] == 0 && (best == -1 || Before(key, i, best)) {
        best := i;
      }
      i := i + 1;
    }
  }

  // Hands out k units one at a time, each to the entry that comes first
  // among those still waiting. That is the rule itself; a sort is a
  // faster way to the same answer.
  method HandOut(key: seq<int>, k: int) returns (got: seq<int>)
    requires 0 <= k <= Sum(Positive(key))
    ensures HandedOut(key, got)
    ensures Sum(got) == k
  {
    var n := |key|;
    got := seq(n, i => 0);
    ghost var zeros := seq(n, i requires 0 <= i < n => 0 * got[i]);
    SumOfMultiples(got, 0, zeros);
    assert zeros == got;

    var handed := 0;
    while handed < k
      invariant 0 <= handed <= k
      invariant |got| == n
      invariant forall i :: 0 <= i < n ==> got[i] == 0 || got[i] == 1
      invariant Sum(got) == handed
      invariant forall i :: 0 <= i < n && got[i] == 1 ==> key[i] > 0
      invariant forall i, j :: 0 <= i < n && 0 <= j < n && got[i] == 1 && got[j] == 0 ==> Before(key, i, j)
    {
      SomeEntryWaits(got, key);
      ghost var waiting :| 0 <= waiting < n && got[waiting] == 0 && key[waiting] > 0;
      var best := First(got, key);
      assert best == waiting || Before(key, best, waiting);
      SumAfterChange(got, best, 1);
      got := got[best := 1];
      handed := handed + 1;
    }
  }

  // Two ways of handing out the same number of units by the order are
  // the same. If an entry got a unit in a and not in b, then since both
  // handed out the same number, another entry got one in b and not in a,
  // and a and b would put those two entries in opposite orders.
  lemma OnlyOneHandOut(key: seq<int>, a: seq<int>, b: seq<int>)
    requires HandedOut(key, a) && HandedOut(key, b)
    requires Sum(a) == Sum(b)
    ensures a == b
  {
    NoUnitOnlyInFirst(key, a, b);
    NoUnitOnlyInFirst(key, b, a);
  }

  lemma NoUnitOnlyInFirst(key: seq<int>, a: seq<int>, b: seq<int>)
    requires HandedOut(key, a) && HandedOut(key, b)
    requires Sum(a) == Sum(b)
    ensures forall i :: 0 <= i < |a| ==> !(a[i] == 1 && b[i] == 0)
  {
    if i :| 0 <= i < |a| && a[i] == 1 && b[i] == 0 {
      if forall j :: 0 <= j < |a| ==> b[j] <= a[j] {
        SumNoLarger(b, a);
        assert false;
      }
      var j :| 0 <= j < |a| && b[j] > a[j];
      assert Before(key, i, j);
      assert Before(key, j, i);
      assert false;
    }
  }
}
