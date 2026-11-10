// Rounding settled balances to cents, proven for every input.
//
// Written from the rule (AGENTS.md, Money Handling Standards, rule 5),
// not from the Ruby in Settlement.allocate_to_cents. Do not edit it to
// match the Ruby: it is a separate copy of the rule, and is useful only
// because it can disagree.
//
// The rule, for balances that sum to exactly zero:
//
//   1. Each balance is cut toward zero to a whole cent: a positive one
//      rounds down, a negative one rounds up.
//   2. The cut balances then sum to some whole number of cents. If it is
//      positive, one cent is taken from each of that many balances, those
//      that lost the most on the negative side in step 1. If it is
//      negative, one cent is given to each of that many balances, those
//      that lost the most on the positive side. Either way each cent moves
//      a balance back toward its exact amount.
//   3. On a tie, the lowest resident id gets the cent.
//
// Balances are whole units (10^-8 dollars), and `cent` is the units in a
// cent (10^6). The proofs hold for any size of cent. The balances are in
// order of resident id, lowest first, so "the lowest id" is "the earlier
// position".
//
// This file proves, for every list of balances that sums to zero:
//
//   - Round always returns a list that follows the rule (IsRounding).
//     That includes summing to exactly zero.
//   - Only one list follows the rule (OnlyOneRounding).
//   - Each rounded balance is a whole number of cents (WholeCents), and
//     less than one cent from its exact amount (WithinOneCent).
//   - There are always enough balances that lost something on the needed
//     side to take the leftover cents (EnoughRemainders). So the guard
//     Settlement.assert_candidates_cover_pennies! can never fire on a
//     list that sums to zero.
module CentRounding {
  import opened Sums
  import opened Arithmetic
  import opened LargestRemainder

  function Abs(x: int): int
  {
    if x < 0 then -x else x
  }

  // One balance cut toward zero, as a number of cents. Dafny's / rounds
  // down for a positive divisor, so a negative balance is cut as the
  // negative of its size cut down.
  function CutCent(cent: int, balance: int): int
    requires cent > 0
  {
    if balance >= 0 then balance / cent else -((-balance) / cent)
  }

  // Each balance cut toward zero, as a number of cents. The lists below
  // are built from one balance at a time, so that the Python made from
  // them (EntryPoints.dfy) does not build a whole list for each entry.
  function CutCents(cent: int, balances: seq<int>): seq<int>
    requires cent > 0
  {
    seq(|balances|, i requires 0 <= i < |balances| => CutCent(cent, balances[i]))
  }

  // Each balance cut toward zero, in units.
  function Cuts(cent: int, balances: seq<int>): seq<int>
    requires cent > 0
  {
    seq(|balances|, i requires 0 <= i < |balances| => cent * CutCent(cent, balances[i]))
  }

  // What the cut lost from each balance: positive when a positive balance
  // was rounded down, negative when a negative one was rounded up.
  function Lost(cent: int, balances: seq<int>): seq<int>
    requires cent > 0
  {
    seq(|balances|, i requires 0 <= i < |balances| => balances[i] - cent * CutCent(cent, balances[i]))
  }

  // The rule, as a test any list of rounded balances passes or fails.
  predicate IsRounding(cent: int, balances: seq<int>, out: seq<int>)
    requires cent > 0
  {
    var cuts := Cuts(cent, balances);
    var lost := Lost(cent, balances);
    && |out| == |balances|
    && Sum(out) == 0
    // Each balance is its cut, or one cent back toward its exact amount.
    && (forall i :: 0 <= i < |out| ==>
          || out[i] == cuts[i]
          || (out[i] == cuts[i] - cent && lost[i] < 0)
          || (out[i] == cuts[i] + cent && lost[i] > 0))
    // The cents all move the same way.
    && (forall i, j :: 0 <= i < |out| && 0 <= j < |out| && out[i] < cuts[i] ==> out[j] <= cuts[j])
    // A cent goes to a balance that lost more on that side than every
    // balance on that side that got none, or the same and earlier.
    && (forall i, j ::
          && 0 <= i < |out| && 0 <= j < |out|
          && out[i] != cuts[i] && out[j] == cuts[j]
          && lost[j] != 0 && (lost[i] < 0 <==> lost[j] < 0)
          ==> Abs(lost[i]) > Abs(lost[j]) || (Abs(lost[i]) == Abs(lost[j]) && i < j))
  }

  // The leftover cents: the cut balances add up to cent * Leftover.
  function Leftover(cent: int, balances: seq<int>): int
    requires cent > 0
  {
    Sum(CutCents(cent, balances))
  }

  // -1 when the cents are taken away (the leftover is not negative), 1
  // when they are given.
  function Direction(cent: int, balances: seq<int>): int
    requires cent > 0
  {
    if Leftover(cent, balances) >= 0 then -1 else 1
  }

  // What each balance lost on the side the cents move: above zero for the
  // balances that can take a cent, and then the size of what they lost.
  function Key(cent: int, balances: seq<int>): seq<int>
    requires cent > 0
  {
    var direction := Direction(cent, balances);
    seq(|balances|, i requires 0 <= i < |balances| => direction * (balances[i] - cent * CutCent(cent, balances[i])))
  }

  // Facts about one balance: its cut is within one cent of it, on the
  // side of zero.
  lemma OneCut(cent: int, balances: seq<int>, i: int)
    requires cent > 0 && 0 <= i < |balances|
    ensures -cent < Lost(cent, balances)[i] < cent
    ensures balances[i] >= 0 ==> Lost(cent, balances)[i] >= 0
    ensures balances[i] < 0 ==> Lost(cent, balances)[i] <= 0
    ensures balances[i] == Cuts(cent, balances)[i] + Lost(cent, balances)[i]
  {
    var b := balances[i];
    assert Cuts(cent, balances)[i] == cent * CutCents(cent, balances)[i];
    assert Lost(cent, balances)[i] == b - Cuts(cent, balances)[i];
    if b >= 0 {
      DivMod(b, cent);
      assert CutCents(cent, balances)[i] == b / cent;
    } else {
      DivMod(-b, cent);
      var q := (-b) / cent;
      assert CutCents(cent, balances)[i] == -q;
      MulNegate(cent, q);
      assert Lost(cent, balances)[i] == -((-b) % cent);
    }
  }

  // The cut balances add up to cent * Leftover, and what the cuts lost
  // adds up to the opposite, since the balances add up to zero.
  lemma LostSum(cent: int, balances: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    ensures Sum(Cuts(cent, balances)) == cent * Leftover(cent, balances)
    ensures Sum(Lost(cent, balances)) == -(cent * Leftover(cent, balances))
  {
    SumOfMultiples(CutCents(cent, balances), cent, Cuts(cent, balances));
    forall i | 0 <= i < |balances|
      ensures balances[i] == Cuts(cent, balances)[i] + Lost(cent, balances)[i]
    {
      OneCut(cent, balances, i);
    }
    SumOfPairs(Cuts(cent, balances), Lost(cent, balances), balances);
  }

  // There are at least as many balances that lost something on the side
  // the cents move as there are leftover cents.
  lemma EnoughRemainders(cent: int, balances: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    ensures Abs(Leftover(cent, balances)) <= Sum(Positive(Key(cent, balances)))
  {
    var dir := Direction(cent, balances);
    var key := Key(cent, balances);
    var k := Abs(Leftover(cent, balances));
    LostSum(cent, balances);
    SumOfMultiples(Lost(cent, balances), dir, key);
    forall i | 0 <= i < |balances|
      ensures key[i] < cent
    {
      OneCut(cent, balances, i);
    }
    CountFits(key, cent, k);
  }

  // The rounding: cut every balance, then move the leftover cents, one
  // each, by LargestRemainder.HandOut in the order of what each balance
  // lost on the side they move.
  method Round(cent: int, balances: seq<int>) returns (out: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    ensures IsRounding(cent, balances, out)
  {
    EnoughRemainders(cent, balances);
    var got := HandOut(Key(cent, balances), Abs(Leftover(cent, balances)));
    out := Build(cent, balances, got);
    BuildFollowsTheRule(cent, balances, got);
  }

  // The cut balances, with one cent moved in Direction for each entry of
  // got that is 1.
  function Build(cent: int, balances: seq<int>, got: seq<int>): seq<int>
    requires cent > 0 && |got| == |balances|
  {
    var direction := Direction(cent, balances);
    seq(|got|, i requires 0 <= i < |got| =>
      if got[i] == 0 then cent * CutCent(cent, balances[i])
      else if direction == -1 then cent * CutCent(cent, balances[i]) - cent
      else cent * CutCent(cent, balances[i]) + cent)
  }

  lemma {:isolate_assertions} BuildFollowsTheRule(cent: int, balances: seq<int>, got: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    requires HandedOut(Key(cent, balances), got)
    requires Sum(got) == Abs(Leftover(cent, balances))
    ensures IsRounding(cent, balances, Build(cent, balances, got))
  {
    var n := |balances|;
    var cuts := Cuts(cent, balances);
    var lost := Lost(cent, balances);
    var dir := Direction(cent, balances);
    var key := Key(cent, balances);
    var leftover := Leftover(cent, balances);
    var out := Build(cent, balances, got);
    LostSum(cent, balances);
    forall i | 0 <= i < n
      ensures -cent < lost[i] < cent
    {
      OneCut(cent, balances, i);
    }

    // The moves add up to the opposite of the cut balances' sum.
    var step := dir * cent;
    var moves := seq(n, i requires 0 <= i < n => step * got[i]);
    SumOfMultiples(got, step, moves);
    SumOfPairs(cuts, moves, out);
    MulNegate(cent, leftover);
    if dir == -1 {
      assert step == -cent;
      MulNegate(cent, Sum(got));
      assert Sum(out) == 0;
      assert forall i :: 0 <= i < n && got[i] == 1 ==> lost[i] < 0 && out[i] == cuts[i] - cent;
      assert forall i :: 0 <= i < n ==> out[i] <= cuts[i];
      assert forall i :: 0 <= i < n && lost[i] < 0 ==> key[i] == Abs(lost[i]);
    } else {
      assert step == cent;
      assert Sum(out) == 0;
      assert forall i :: 0 <= i < n && got[i] == 1 ==> lost[i] > 0 && out[i] == cuts[i] + cent;
      assert forall i :: 0 <= i < n ==> out[i] >= cuts[i];
      assert forall i :: 0 <= i < n && lost[i] > 0 ==> key[i] == Abs(lost[i]);
    }
    assert forall i :: 0 <= i < n ==> (out[i] != cuts[i] <==> got[i] == 1);
  }

  // Which balances a rounding moved: 1 for a balance it moved off its cut.
  function Moved(cent: int, balances: seq<int>, out: seq<int>): seq<int>
    requires cent > 0 && |out| == |balances|
  {
    seq(|out|, i requires 0 <= i < |out| => if out[i] != Cuts(cent, balances)[i] then 1 else 0)
  }

  // In any rounding that follows the rule, the cents move in Direction:
  // taken when the leftover is not negative, given when it is negative.
  // If one moved the other way, every move would be that way, and the
  // moves would not add up to the opposite of the leftover.
  lemma CentsMoveInDirection(cent: int, balances: seq<int>, out: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    requires IsRounding(cent, balances, out)
    ensures Direction(cent, balances) == -1 ==> forall i :: 0 <= i < |out| ==> out[i] <= Cuts(cent, balances)[i]
    ensures Direction(cent, balances) == 1 ==> forall i :: 0 <= i < |out| ==> out[i] >= Cuts(cent, balances)[i]
  {
    var n := |out|;
    var cuts := Cuts(cent, balances);
    var leftover := Leftover(cent, balances);
    LostSum(cent, balances);
    var moves := seq(n, i requires 0 <= i < n => out[i] - cuts[i]);
    SumOfPairs(cuts, moves, out);
    assert Sum(moves) == -(cent * leftover);
    var zeros := seq(n, i requires 0 <= i < n => 0);
    SumOfMultiples(moves, 0, zeros);
    if Direction(cent, balances) == -1 {
      MulKeepsOrder(cent, 0, leftover);
      if j :| 0 <= j < n && out[j] > cuts[j] {
        assert forall i :: 0 <= i < n ==> zeros[i] <= moves[i];
        SumNoLarger(zeros, moves);
        assert false;
      }
    } else {
      MulNegative(cent, leftover);
      if j :| 0 <= j < n && out[j] < cuts[j] {
        assert forall i :: 0 <= i < n ==> moves[i] <= zeros[i];
        SumNoLarger(moves, zeros);
        assert false;
      }
    }
  }

  // In any rounding that follows the rule, as many balances moved as
  // there are leftover cents.
  lemma AsManyMovedAsLeftOver(cent: int, balances: seq<int>, out: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    requires IsRounding(cent, balances, out)
    ensures Sum(Moved(cent, balances, out)) == Abs(Leftover(cent, balances))
  {
    var n := |out|;
    var cuts := Cuts(cent, balances);
    var moved := Moved(cent, balances, out);
    var leftover := Leftover(cent, balances);
    LostSum(cent, balances);
    CentsMoveInDirection(cent, balances, out);
    var moves := seq(n, i requires 0 <= i < n => out[i] - cuts[i]);
    SumOfPairs(cuts, moves, out);
    assert Sum(moves) == -(cent * leftover);
    if Direction(cent, balances) == -1 {
      forall i | 0 <= i < n
        ensures moves[i] == -cent * moved[i]
      {
        if moved[i] == 1 {
          assert moves[i] == -cent;
        } else {
          assert moves[i] == 0;
        }
      }
      SumOfMultiples(moved, -cent, moves);
      MulNegate(cent, Sum(moved));
      MulCancel(cent, Sum(moved), leftover);
    } else {
      forall i | 0 <= i < n
        ensures moves[i] == cent * moved[i]
      {
        if moved[i] == 1 {
          assert moves[i] == cent;
        } else {
          assert moves[i] == 0;
        }
      }
      SumOfMultiples(moved, cent, moves);
      MulNegate(cent, leftover);
      MulCancel(cent, Sum(moved), -leftover);
    }
  }

  // Any rounding that follows the rule is Build of the balances it moved,
  // and those were handed out by HandOut's order. So it is what Round
  // gives.
  lemma RoundingIsAHandOut(cent: int, balances: seq<int>, out: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    requires IsRounding(cent, balances, out)
    ensures HandedOut(Key(cent, balances), Moved(cent, balances, out))
    ensures Sum(Moved(cent, balances, out)) == Abs(Leftover(cent, balances))
    ensures out == Build(cent, balances, Moved(cent, balances, out))
  {
    var n := |out|;
    var cuts := Cuts(cent, balances);
    var lost := Lost(cent, balances);
    var key := Key(cent, balances);
    var moved := Moved(cent, balances, out);
    CentsMoveInDirection(cent, balances, out);
    AsManyMovedAsLeftOver(cent, balances, out);
    if Direction(cent, balances) == -1 {
      assert forall i :: 0 <= i < n && moved[i] == 1 ==> out[i] == cuts[i] - cent && lost[i] < 0;
      assert forall i :: 0 <= i < n && lost[i] < 0 ==> key[i] == Abs(lost[i]);
      assert forall i :: 0 <= i < n && lost[i] >= 0 ==> key[i] <= 0;
    } else {
      assert forall i :: 0 <= i < n && moved[i] == 1 ==> out[i] == cuts[i] + cent && lost[i] > 0;
      assert forall i :: 0 <= i < n && lost[i] > 0 ==> key[i] == Abs(lost[i]);
      assert forall i :: 0 <= i < n && lost[i] <= 0 ==> key[i] <= 0;
    }
    assert out == Build(cent, balances, moved);
  }

  // Two lists that both follow the rule are the same list.
  lemma OnlyOneRounding(cent: int, balances: seq<int>, a: seq<int>, b: seq<int>)
    requires cent > 0 && Sum(balances) == 0
    requires IsRounding(cent, balances, a) && IsRounding(cent, balances, b)
    ensures a == b
  {
    RoundingIsAHandOut(cent, balances, a);
    RoundingIsAHandOut(cent, balances, b);
    OnlyOneHandOut(Key(cent, balances), Moved(cent, balances, a), Moved(cent, balances, b));
  }

  // Each rounded balance is a whole number of cents.
  lemma WholeCents(cent: int, balances: seq<int>, out: seq<int>, i: int)
    requires cent > 0
    requires IsRounding(cent, balances, out)
    requires 0 <= i < |out|
    ensures out[i] % cent == 0
  {
    var c := CutCents(cent, balances)[i];
    var cut := Cuts(cent, balances)[i];
    assert cut == cent * c;
    // out[i] is the cut, a cent below it, or a cent above it: cent times
    // c, c - 1 or c + 1.
    var m := if out[i] == cut then c else if out[i] < cut then c - 1 else c + 1;
    MulAdd(cent, c, -1);
    MulAdd(cent, c, 1);
    assert out[i] == cent * m;
    MultipleHasNoRemainder(cent, m);
  }

  // Each rounded balance is less than one cent from its exact amount.
  lemma WithinOneCent(cent: int, balances: seq<int>, out: seq<int>, i: int)
    requires cent > 0
    requires IsRounding(cent, balances, out)
    requires 0 <= i < |out|
    ensures -cent < out[i] - balances[i] < cent
  {
    OneCut(cent, balances, i);
  }

  // Worked examples, in units, with a cent of 10^6 units. A proof shows
  // that Round follows IsRounding, but not that IsRounding says what the
  // rule says: a mistake in IsRounding would be made in Round too. These
  // pin IsRounding to answers worked out by hand from the rule. Since only
  // one list follows the rule (OnlyOneRounding), each one is the only
  // answer for its input.

  // Two people each owe half a cent, and one is owed a cent. The cuts are
  // 0, 0 and 1 cent, which leaves one cent to take back. Both owers lost
  // half a cent, so the tie goes to the lowest id.
  lemma TiesGoToTheLowestId()
    ensures IsRounding(1000000, [-500000, -500000, 1000000], [-1000000, 0, 1000000])
  {
    SumOfFour(-1000000, 0, 1000000, 0);
    assert CutCents(1000000, [-500000, -500000, 1000000]) == [0, 0, 1];
    assert Cuts(1000000, [-500000, -500000, 1000000]) == [0, 0, 1000000];
    assert Lost(1000000, [-500000, -500000, 1000000]) == [-500000, -500000, 0];
  }

  // The one leftover cent is taken from the second balance, which lost
  // 0.8 cents in the cut, not from the first, which lost 0.3.
  lemma TheBalanceThatLostMostGoesFirst()
    ensures IsRounding(1000000, [-300000, -800000, 1100000], [0, -1000000, 1000000])
  {
    SumOfFour(0, -1000000, 1000000, 0);
    assert CutCents(1000000, [-300000, -800000, 1100000]) == [0, 0, 1];
    assert Cuts(1000000, [-300000, -800000, 1100000]) == [0, 0, 1000000];
    assert Lost(1000000, [-300000, -800000, 1100000]) == [-300000, -800000, 100000];
  }

  // The cuts sum to minus one cent, so a cent is given, to the balance
  // that lost the most on the positive side. Two tie at 0.7 cents, and
  // the lowest id gets it.
  lemma ACentIsGivenWhenTheCutsSumBelowZero()
    ensures IsRounding(1000000, [700000, 700000, -1400000], [1000000, 0, -1000000])
  {
    SumOfFour(1000000, 0, -1000000, 0);
    assert CutCents(1000000, [700000, 700000, -1400000]) == [0, 0, -1];
    assert Cuts(1000000, [700000, 700000, -1400000]) == [0, 0, -1000000];
    assert Lost(1000000, [700000, 700000, -1400000]) == [700000, 700000, -400000];
  }

  // The cuts sum to zero, so no cent moves: 0.4, 0.4 and -0.8 cents all
  // become 0.
  lemma NothingMovesWhenTheCutsSumToZero()
    ensures IsRounding(1000000, [400000, 400000, -800000], [0, 0, 0])
  {
    SumOfFour(0, 0, 0, 0);
    assert CutCents(1000000, [400000, 400000, -800000]) == [0, 0, 0];
    assert Cuts(1000000, [400000, 400000, -800000]) == [0, 0, 0];
    assert Lost(1000000, [400000, 400000, -800000]) == [400000, 400000, -800000];
  }
}
