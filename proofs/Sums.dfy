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
}
