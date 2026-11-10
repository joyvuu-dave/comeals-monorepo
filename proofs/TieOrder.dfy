// The tie-break order, and a sort into it.
//
// The split and the cent rounding give a tie to the earlier position
// (LargestRemainder.dfy). The rules say which row is earlier: the lowest
// resident id, then an attendee before a guest of the same resident, then
// the lower guest id (MODELS.md, "The ledger grain", step 3; AGENTS.md,
// Money Handling Standards, rule 5). So each row gets a key, a short list
// of numbers, and rows are put in order of their keys: first numbers
// compared first, and the next only on a tie.
//
// This file proves that Sort puts any list of rows in that order without
// losing or adding a row (Sort), and that only one order of a list does
// that (OnlyOneOrder). Both need every row to have a different key, and
// every key to be the same length, so that any two rows have an order.
module TieOrder {
  // a comes before b: its first number is smaller, or the same and the
  // rest of a comes before the rest of b.
  predicate Less(a: seq<int>, b: seq<int>)
  {
    |a| > 0 && |b| > 0 && (a[0] < b[0] || (a[0] == b[0] && Less(a[1..], b[1..])))
  }

  lemma NotLessThanItself(a: seq<int>)
    ensures !Less(a, a)
  {
    if |a| > 0 {
      NotLessThanItself(a[1..]);
    }
  }

  lemma LessThenLess(a: seq<int>, b: seq<int>, c: seq<int>)
    requires Less(a, b) && Less(b, c)
    ensures Less(a, c)
  {
    if a[0] == b[0] && b[0] == c[0] {
      LessThenLess(a[1..], b[1..], c[1..]);
    }
  }

  // Two different keys of the same length are in one order or the other.
  lemma OneOrTheOther(a: seq<int>, b: seq<int>)
    requires |a| == |b| && a != b
    ensures Less(a, b) || Less(b, a)
  {
    if a[0] == b[0] {
      assert a == [a[0]] + a[1..] && b == [b[0]] + b[1..];
      OneOrTheOther(a[1..], b[1..]);
    }
  }

  // Every row's key has n numbers, and no two rows have the same key.
  predicate Keyed<T>(s: seq<T>, key: T -> seq<int>, n: nat)
  {
    && (forall i :: 0 <= i < |s| ==> |key(s[i])| == n)
    && (forall i, j :: 0 <= i < j < |s| ==> key(s[i]) != key(s[j]))
  }

  predicate Sorted<T>(s: seq<T>, key: T -> seq<int>)
  {
    forall i, j :: 0 <= i < j < |s| ==> Less(key(s[i]), key(s[j]))
  }

  // Insertion sort: each row in turn goes in after every row before it in
  // the order, and before every row after it.
  method Sort<T>(s: seq<T>, key: T -> seq<int>, ghost n: nat) returns (t: seq<T>)
    requires Keyed(s, key, n)
    ensures multiset(t) == multiset(s)
    ensures Sorted(t, key)
  {
    t := [];
    var i := 0;
    while i < |s|
      invariant 0 <= i <= |s|
      invariant multiset(t) == multiset(s[..i])
      invariant Sorted(t, key)
    {
      var x := s[i];
      forall y | y in t
        ensures |key(y)| == n && key(y) != key(x)
      {
        assert y in multiset(s[..i]);
        var j :| 0 <= j < i && s[j] == y;
      }
      t := Insert(t, x, key, n);
      assert s[..i + 1] == s[..i] + [x];
      i := i + 1;
    }
    assert s[..|s|] == s;
  }

  method Insert<T>(t: seq<T>, x: T, key: T -> seq<int>, ghost n: nat) returns (u: seq<T>)
    requires Sorted(t, key)
    requires |key(x)| == n
    requires forall y :: y in t ==> |key(y)| == n && key(y) != key(x)
    ensures multiset(u) == multiset(t) + multiset{x}
    ensures Sorted(u, key)
  {
    var p := 0;
    while p < |t| && !Less(key(x), key(t[p]))
      invariant 0 <= p <= |t|
      invariant forall q :: 0 <= q < p ==> Less(key(t[q]), key(x))
    {
      assert t[p] in t;
      OneOrTheOther(key(x), key(t[p]));
      p := p + 1;
    }
    // Every row from p on comes after x: t[p] does, and the rest come
    // after t[p].
    forall q | p <= q < |t|
      ensures Less(key(x), key(t[q]))
    {
      if q > p {
        LessThenLess(key(x), key(t[p]), key(t[q]));
      }
    }
    u := t[..p] + [x] + t[p..];
    assert t == t[..p] + t[p..];
    forall a, b | 0 <= a < b < |u|
      ensures Less(key(u[a]), key(u[b]))
    {
      if a < p && b == p {
      } else if a < p && b > p {
        assert u[b] == t[b - 1];
        LessThenLess(key(u[a]), key(x), key(u[b]));
      } else if a == p {
        assert u[b] == t[b - 1];
      } else if a < p {
      } else {
        assert u[a] == t[a - 1] && u[b] == t[b - 1];
      }
    }
  }

  // Two sorted lists of the same rows are the same list. The first rows
  // are the same (SameFirst), and so are the rest, by the same argument.
  lemma OnlyOneOrder<T>(a: seq<T>, b: seq<T>, key: T -> seq<int>)
    requires Sorted(a, key) && Sorted(b, key)
    requires multiset(a) == multiset(b)
    ensures a == b
    decreases |a|
  {
    assert |a| == |multiset(a)| == |multiset(b)| == |b|;
    if |a| > 0 {
      SameFirst(a, b, key);
      Rest(a);
      Rest(b);
      OnlyOneOrder(a[1..], b[1..], key);
      assert a == [a[0]] + a[1..] && b == [b[0]] + b[1..];
    }
  }

  // The first row of a is somewhere in b, and the first row of b is
  // somewhere in a. If b's first row were not a's, it would come before
  // a's first row in b and after it in a.
  lemma SameFirst<T>(a: seq<T>, b: seq<T>, key: T -> seq<int>)
    requires Sorted(a, key) && Sorted(b, key)
    requires multiset(a) == multiset(b)
    requires |a| > 0 && |b| > 0
    ensures a[0] == b[0]
  {
    assert a[0] in multiset(b);
    var j :| 0 <= j < |b| && b[j] == a[0];
    assert b[0] in multiset(a);
    var i :| 0 <= i < |a| && a[i] == b[0];
    if j > 0 {
      assert Less(key(b[0]), key(a[0]));
      if i == 0 {
        NotLessThanItself(key(a[0]));
      } else {
        assert Less(key(a[0]), key(b[0]));
        LessThenLess(key(a[0]), key(b[0]), key(a[0]));
        NotLessThanItself(key(a[0]));
      }
    }
  }

  lemma Rest<T>(s: seq<T>)
    requires |s| > 0
    ensures multiset(s[1..]) == multiset(s) - multiset{s[0]}
  {
    assert s == [s[0]] + s[1..];
  }
}
