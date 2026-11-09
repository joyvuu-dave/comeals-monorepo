// The sum of a list of whole numbers, and the facts about it that the
// money proofs use. Every rule they prove is about a sum: the shares of
// a split sum to the total, the lines of a dinner sum to zero, the
// rounded balances sum to zero.
//
// Sum takes the last element off, not the first, so that adding one
// element at the end (what a loop does) needs no lemma.
module Sums {
  function Sum(s: seq<int>): int
  {
    if |s| == 0 then 0 else Sum(s[..|s| - 1]) + s[|s| - 1]
  }

  // The sum of two lists put together is the sum of each.
  lemma SumOfJoined(a: seq<int>, b: seq<int>)
    ensures Sum(a + b) == Sum(a) + Sum(b)
  {
    if |b| == 0 {
      assert a + b == a;
    } else {
      SumOfJoined(a, b[..|b| - 1]);
      assert (a + b)[..|a + b| - 1] == a + b[..|b| - 1];
    }
  }

  // Adding one to the element at position i adds one to the sum. A split
  // hands out its leftover units this way, and the cent rounding its
  // leftover cents.
  lemma SumAfterChange(s: seq<int>, i: nat, delta: int)
    requires i < |s|
    ensures Sum(s[i := s[i] + delta]) == Sum(s) + delta
  {
    var changed := s[i := s[i] + delta];
    assert s == s[..i] + [s[i]] + s[i + 1..];
    assert changed == s[..i] + [s[i] + delta] + s[i + 1..];
    SumOfJoined(s[..i] + [s[i]], s[i + 1..]);
    SumOfJoined(s[..i], [s[i]]);
    SumOfJoined(s[..i] + [s[i] + delta], s[i + 1..]);
    SumOfJoined(s[..i], [s[i] + delta]);
  }

  // Adding two lists element by element adds their sums.
  lemma SumOfPairs(a: seq<int>, b: seq<int>, c: seq<int>)
    requires |a| == |b| == |c|
    requires forall i :: 0 <= i < |c| ==> c[i] == a[i] + b[i]
    ensures Sum(c) == Sum(a) + Sum(b)
  {
    if |c| > 0 {
      SumOfPairs(a[..|a| - 1], b[..|b| - 1], c[..|c| - 1]);
    }
  }

  // Multiplying every element by k multiplies the sum by k.
  lemma SumOfMultiples(a: seq<int>, k: int, b: seq<int>)
    requires |a| == |b|
    requires forall i :: 0 <= i < |b| ==> b[i] == k * a[i]
    ensures Sum(b) == k * Sum(a)
  {
    if |b| > 0 {
      SumOfMultiples(a[..|a| - 1], k, b[..|b| - 1]);
    }
  }

  // A list that is no larger at any position has no larger a sum, and a
  // smaller one if it is smaller at some position.
  lemma SumNoLarger(a: seq<int>, b: seq<int>)
    requires |a| == |b|
    requires forall i :: 0 <= i < |a| ==> a[i] <= b[i]
    ensures Sum(a) <= Sum(b)
    ensures (exists i :: 0 <= i < |a| && a[i] < b[i]) ==> Sum(a) < Sum(b)
  {
    if |a| > 0 {
      SumNoLarger(a[..|a| - 1], b[..|b| - 1]);
      if exists i :: 0 <= i < |a| && a[i] < b[i] {
        var i :| 0 <= i < |a| && a[i] < b[i];
        if i < |a| - 1 {
          assert a[..|a| - 1][i] < b[..|b| - 1][i];
        }
      }
    }
  }

  // The sums of short lists written out, for worked examples.
  lemma SumOfFour(a: int, b: int, c: int, d: int)
    ensures Sum([a]) == a
    ensures Sum([a, b]) == a + b
    ensures Sum([a, b, c]) == a + b + c
    ensures Sum([a, b, c, d]) == a + b + c + d
  {
    assert [a, b, c, d][..3] == [a, b, c];
    assert [a, b, c][..2] == [a, b];
    assert [a, b][..1] == [a];
    assert [a][..0] == [];
  }
}
