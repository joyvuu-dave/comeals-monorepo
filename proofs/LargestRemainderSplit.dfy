// The largest remainder split (Hamilton's method), proven for every input.
//
// Written from the rule (AGENTS.md, Money Handling Standards, rules 4
// and 5; MODELS.md, "The ledger grain"), not from the Ruby in
// app/services/largest_remainder_split.rb. Do not edit it to match the
// Ruby: it is a separate copy of the rule, and is useful only because it
// can disagree.
//
// The rule: share `total` whole units out in proportion to `weights`.
//
//   1. Each share first gets its exact share, total * weight / (sum of
//      the weights), rounded down.
//   2. The units left over go one each to the shares that dropped the
//      most in step 1.
//   3. On a tie, the earlier position gets the unit.
//
// This file proves:
//
//   - Split always returns a list that follows the rule (IsSplit): the
//     shares sum to the total, each is its exact share rounded down or
//     one more, a share whose exact share is whole gets no extra unit,
//     and the extra units go in the order of rules 2 and 3.
//   - Only one list follows the rule (OnlyOneSplit). So a program that
//     follows the rule on some input gives the same shares as Split on
//     that input, however it computes them.
//   - Each share is less than one unit from its exact share
//     (WithinOneUnit).
//
// Units are whole numbers: 10^-8 dollars for the ledger. Dafny's int has
// no size limit, so nothing here can overflow.
module LargestRemainderSplit {
  import opened Sums
  import opened Arithmetic

  // Each exact share rounded down. Dafny's / rounds down for a positive
  // divisor.
  function Floors(total: nat, weights: seq<nat>): seq<int>
    requires Sum(weights) > 0
  {
    seq(|weights|, i requires 0 <= i < |weights| => total * weights[i] / Sum(weights))
  }

  // What rounding down dropped from each exact share, as a numerator over
  // the sum of the weights. Comparing these compares the dropped
  // fractions exactly, since the denominator is the same for every share.
  function Dropped(total: nat, weights: seq<nat>): seq<int>
    requires Sum(weights) > 0
  {
    seq(|weights|, i requires 0 <= i < |weights| => total * weights[i] % Sum(weights))
  }

  // 1 for a share that dropped something, 0 for one that did not.
  function DroppedSomething(dropped: seq<int>): seq<int>
  {
    seq(|dropped|, i requires 0 <= i < |dropped| => if dropped[i] > 0 then 1 else 0)
  }

  // Share i comes before share j in the order the leftover units are
  // handed out: it dropped more, or the same and it is earlier.
  predicate Before(dropped: seq<int>, i: int, j: int)
    requires 0 <= i < |dropped| && 0 <= j < |dropped|
  {
    dropped[i] > dropped[j] || (dropped[i] == dropped[j] && i < j)
  }

  // The rule, as a test any list of shares passes or fails.
  predicate IsSplit(total: nat, weights: seq<nat>, shares: seq<int>)
    requires Sum(weights) > 0
  {
    var floors := Floors(total, weights);
    var dropped := Dropped(total, weights);
    && |shares| == |weights|
    && Sum(shares) == total
    && (forall i :: 0 <= i < |shares| ==> shares[i] == floors[i] || shares[i] == floors[i] + 1)
    && (forall i :: 0 <= i < |shares| && dropped[i] == 0 ==> shares[i] == floors[i])
    && (forall i, j ::
          0 <= i < |shares| && 0 <= j < |shares| && shares[i] == floors[i] + 1 && shares[j] == floors[j]
          ==> Before(dropped, i, j))
  }

  // The units left over after step 1 are never negative, and never more
  // than the shares that dropped something, so step 2 can always hand
  // them out to shares that dropped something.
  lemma LeftoverFits(total: nat, weights: seq<nat>)
    requires Sum(weights) > 0
    ensures 0 <= total - Sum(Floors(total, weights)) <= Sum(DroppedSomething(Dropped(total, weights)))
  {
    var whole := Sum(weights);
    var n := |weights|;
    var floors := Floors(total, weights);
    var dropped := Dropped(total, weights);
    var some := DroppedSomething(dropped);
    var leftover := total - Sum(floors);
    var count := Sum(some);

    // The exact numerators add up to total * whole ...
    var exact := seq(n, i requires 0 <= i < n => total * weights[i]);
    SumOfMultiples(weights, total, exact);
    // ... and each is its rounded-down share times whole, plus what was
    // dropped. So what was dropped adds up to whole * leftover.
    var kept := seq(n, i requires 0 <= i < n => whole * floors[i]);
    SumOfMultiples(floors, whole, kept);
    forall i | 0 <= i < n
      ensures exact[i] == kept[i] + dropped[i]
    {
      DivMod(total * weights[i], whole);
    }
    SumOfPairs(kept, dropped, exact);
    MulDifference(whole, total, Sum(floors));
    assert Sum(dropped) == whole * leftover;

    // Nothing dropped is negative, so leftover is not negative.
    var zeros := seq(n, i requires 0 <= i < n => 0);
    SumOfMultiples(dropped, 0, zeros);
    forall i | 0 <= i < n
      ensures 0 <= dropped[i] < whole
    {
      DivMod(total * weights[i], whole);
    }
    SumNoLarger(zeros, dropped);
    if leftover < 0 {
      MulNegative(whole, leftover);
    }

    // Each share dropped at most whole - 1, so what was dropped adds up
    // to at most (whole - 1) times the shares that dropped something.
    var most := seq(n, i requires 0 <= i < n => (whole - 1) * some[i]);
    SumOfMultiples(some, whole - 1, most);
    SumNoLarger(dropped, most);
    assert whole * leftover <= (whole - 1) * count;

    // And (whole - 1) * count < whole * (count + 1), so leftover <= count.
    var zeros2 := seq(n, i requires 0 <= i < n => 0);
    SumOfMultiples(some, 0, zeros2);
    SumNoLarger(zeros2, some);
    if leftover > count {
      MulKeepsOrder(whole, count + 1, leftover);
      MulOneMore(count, whole);
      MulOneLess(whole, count);
      assert false;
    }
  }

  // If fewer shares got a unit than dropped something, and every share
  // that got one dropped something, then one that dropped something is
  // still waiting for one.
  lemma SomeShareWaits(got: seq<int>, dropped: seq<int>)
    requires |got| == |dropped|
    requires forall i :: 0 <= i < |got| ==> got[i] == 0 || got[i] == 1
    requires forall i :: 0 <= i < |got| && got[i] == 1 ==> dropped[i] > 0
    requires Sum(got) < Sum(DroppedSomething(dropped))
    ensures exists u :: 0 <= u < |got| && got[u] == 0 && dropped[u] > 0
  {
    if forall u :: 0 <= u < |got| && got[u] == 0 ==> dropped[u] <= 0 {
      SumNoLarger(DroppedSomething(dropped), got);
    }
  }

  // The share that comes first, among those that have not got a unit.
  method First(got: seq<int>, dropped: seq<int>) returns (best: int)
    requires |got| == |dropped|
    requires exists u :: 0 <= u < |got| && got[u] == 0
    ensures 0 <= best < |got| && got[best] == 0
    ensures forall j :: 0 <= j < |got| && got[j] == 0 && j != best ==> Before(dropped, best, j)
  {
    best := -1;
    var i := 0;
    while i < |got|
      invariant 0 <= i <= |got|
      invariant best == -1 ==> forall j :: 0 <= j < i ==> got[j] != 0
      invariant best != -1 ==> 0 <= best < i && got[best] == 0
      invariant best != -1 ==> forall j :: 0 <= j < i && got[j] == 0 && j != best ==> Before(dropped, best, j)
    {
      if got[i] == 0 && (best == -1 || Before(dropped, i, best)) {
        best := i;
      }
      i := i + 1;
    }
  }

  // The split. It hands the leftover units out one at a time, each to
  // the share that comes first among those still waiting. That is the
  // rule itself; a sort is a faster way to the same answer.
  method Split(total: nat, weights: seq<nat>) returns (shares: seq<int>)
    requires Sum(weights) > 0
    ensures IsSplit(total, weights, shares)
  {
    var n := |weights|;
    var floors := Floors(total, weights);
    var dropped := Dropped(total, weights);
    var leftover := total - Sum(floors);
    LeftoverFits(total, weights);

    // 1 for a share that has got a leftover unit.
    var got := seq(n, i => 0);
    var zeros := seq(n, i requires 0 <= i < n => 0 * got[i]);
    SumOfMultiples(got, 0, zeros);
    assert zeros == got;

    var handed := 0;
    while handed < leftover
      invariant 0 <= handed <= leftover
      invariant |got| == n
      invariant forall i :: 0 <= i < n ==> got[i] == 0 || got[i] == 1
      invariant Sum(got) == handed
      invariant forall i :: 0 <= i < n && got[i] == 1 ==> dropped[i] > 0
      invariant forall i, j :: 0 <= i < n && 0 <= j < n && got[i] == 1 && got[j] == 0 ==> Before(dropped, i, j)
    {
      SomeShareWaits(got, dropped);
      var waiting :| 0 <= waiting < n && got[waiting] == 0 && dropped[waiting] > 0;
      var best := First(got, dropped);
      assert best == waiting || Before(dropped, best, waiting);
      SumAfterChange(got, best, 1);
      got := got[best := 1];
      handed := handed + 1;
    }

    shares := seq(n, i requires 0 <= i < n => floors[i] + got[i]);
    SumOfPairs(floors, got, shares);
  }

  // Two lists that both follow the rule are the same list.
  lemma OnlyOneSplit(total: nat, weights: seq<nat>, a: seq<int>, b: seq<int>)
    requires Sum(weights) > 0
    requires IsSplit(total, weights, a) && IsSplit(total, weights, b)
    ensures a == b
  {
    NoShareGotOnlyInFirst(total, weights, a, b);
    NoShareGotOnlyInFirst(total, weights, b, a);
  }

  // No share got a unit in a and not in b. If one had, then since both
  // sum to the total, some other share got a unit in b and not in a, and
  // a and b would put those two shares in opposite orders.
  lemma NoShareGotOnlyInFirst(total: nat, weights: seq<nat>, a: seq<int>, b: seq<int>)
    requires Sum(weights) > 0
    requires IsSplit(total, weights, a) && IsSplit(total, weights, b)
    ensures forall i :: 0 <= i < |a| ==> !(a[i] == Floors(total, weights)[i] + 1 && b[i] == Floors(total, weights)[i])
  {
    var floors := Floors(total, weights);
    var dropped := Dropped(total, weights);
    if i :| 0 <= i < |a| && a[i] == floors[i] + 1 && b[i] == floors[i] {
      if forall j :: 0 <= j < |a| ==> b[j] <= a[j] {
        SumNoLarger(b, a);
        assert false;
      }
      var j :| 0 <= j < |a| && b[j] > a[j];
      assert Before(dropped, i, j);
      assert Before(dropped, j, i);
      assert false;
    }
  }

  // Each share is less than one unit from its exact share:
  // |share - total * weight / whole| < 1, with both sides times whole.
  lemma WithinOneUnit(total: nat, weights: seq<nat>, shares: seq<int>, i: int)
    requires Sum(weights) > 0
    requires IsSplit(total, weights, shares)
    requires 0 <= i < |shares|
    ensures -Sum(weights) < shares[i] * Sum(weights) - total * weights[i] < Sum(weights)
  {
    var whole := Sum(weights);
    var x := total * weights[i];
    var floor := Floors(total, weights)[i];
    var dropped := Dropped(total, weights)[i];
    DivMod(x, whole);
    assert x == whole * floor + dropped;
    if shares[i] == floor {
      assert shares[i] * whole == whole * floor;
    } else {
      MulOneMore(floor, whole);
      assert shares[i] * whole == whole * floor + whole;
    }
  }

  // Worked examples. A proof shows that Split follows IsSplit, but not
  // that IsSplit says what the rule says: a mistake in IsSplit would be
  // made in Split too. These pin IsSplit to answers worked out by hand
  // from the rule. Since only one list follows the rule (OnlyOneSplit),
  // each one is the only answer for its input.

  // MODELS.md, "The ledger grain": $60 across three adults and a
  // half-price child. The exact shares are 1714285714.28... for each
  // adult and 857142857.14... for the child, so the one leftover unit
  // goes to the first adult.
  lemma SixtyDollarsAcrossThreeAdultsAndAChild()
    ensures Sum([2, 2, 2, 1]) == 7
    ensures IsSplit(6000000000, [2, 2, 2, 1], [1714285715, 1714285714, 1714285714, 857142857])
  {
    SumOfFour(2, 2, 2, 1);
    SumOfFour(1714285715, 1714285714, 1714285714, 857142857);
    assert Floors(6000000000, [2, 2, 2, 1]) == [1714285714, 1714285714, 1714285714, 857142857];
    assert Dropped(6000000000, [2, 2, 2, 1]) == [2, 2, 2, 1];
  }

  // A tie goes to the earlier position.
  lemma TiesGoToTheEarlierPosition()
    ensures Sum([1, 1, 1]) == 3
    ensures IsSplit(1, [1, 1, 1], [1, 0, 0])
    ensures IsSplit(2, [1, 1, 1], [1, 1, 0])
  {
    SumOfFour(1, 1, 1, 0);
    SumOfFour(1, 0, 0, 0);
    SumOfFour(1, 1, 0, 0);
    assert Floors(1, [1, 1, 1]) == [0, 0, 0];
    assert Dropped(1, [1, 1, 1]) == [1, 1, 1];
    assert Floors(2, [1, 1, 1]) == [0, 0, 0];
    assert Dropped(2, [1, 1, 1]) == [2, 2, 2];
  }

  // 2 across weights 2, 1, 1: the exact shares are 1, 0.5 and 0.5. The
  // first is whole, so it gets nothing extra although it comes first.
  lemma AWholeShareGetsNoExtraUnit()
    ensures Sum([2, 1, 1]) == 4
    ensures IsSplit(2, [2, 1, 1], [1, 1, 0])
  {
    SumOfFour(2, 1, 1, 0);
    SumOfFour(1, 1, 0, 0);
    assert Floors(2, [2, 1, 1]) == [1, 0, 0];
    assert Dropped(2, [2, 1, 1]) == [0, 2, 2];
  }

  // 10 across weights 1 and 2: the exact shares are 3.33 and 6.67, and
  // the second dropped more, so it gets the unit although it is later.
  lemma TheShareThatDroppedMostGoesFirst()
    ensures Sum([1, 2]) == 3
    ensures IsSplit(10, [1, 2], [3, 7])
  {
    SumOfFour(1, 2, 0, 0);
    SumOfFour(3, 7, 0, 0);
    assert Floors(10, [1, 2]) == [3, 6];
    assert Dropped(10, [1, 2]) == [1, 2];
  }

  // A weight of zero gets nothing.
  lemma AZeroWeightGetsNothing()
    ensures Sum([0, 1, 1, 1]) == 3
    ensures IsSplit(2, [0, 1, 1, 1], [0, 1, 1, 0])
  {
    SumOfFour(0, 1, 1, 1);
    SumOfFour(0, 1, 1, 0);
    assert Floors(2, [0, 1, 1, 1]) == [0, 0, 0, 0];
    assert Dropped(2, [0, 1, 1, 1]) == [0, 2, 2, 2];
  }
}
