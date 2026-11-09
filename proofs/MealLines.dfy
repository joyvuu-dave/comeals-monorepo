// The lines of one dinner, proven for every dinner.
//
// Written from the rules (MODELS.md, "Financial Models", "The ledger
// grain" and "The Multiplier System"), not from the Ruby in
// app/services/meal_ledger.rb. Do not edit it to match the Ruby: it is a
// separate copy of the rules, and is useful only because it can disagree.
//
// The rules, for one dinner:
//
//   1. The total cost is what the cooks spent. A bill marked No cost is
//      left out before anything here sees it.
//   2. The effective cost is what the eaters are charged for:
//        - 0 on a cancelled dinner;
//        - 0 when the total multiplier is 0 (nobody there can be charged);
//        - otherwise the total cost, but no more than the cap times the
//          total multiplier when the dinner has a cap.
//   3. The dinner is subsidized when the effective cost is less than the
//      total cost.
//   4. Each eater is charged a share of the effective cost, split by
//      multiplier (LargestRemainderSplit.dfy). When the total multiplier
//      is 0 there is nothing to split by, and every charge is 0.
//   5. Each cook is credited what they spent. On a subsidized dinner,
//      the cooks instead share the effective cost, split by what each
//      spent.
//
// The split gives ties to the earlier position. So the cooks come in
// order of resident id, and the eaters in the tie-break order of MODELS.md
// ("The ledger grain", step 3): lowest resident id first, an attendee
// before a guest of the same resident, and between two guests of one host
// the lower guest id. This file takes both lists already in that order.
//
// A charge here is a positive number. On the dinner's line it is negated
// (MealLedger, "Signs"), so "the lines sum to zero" is "the credits sum
// to the same number as the charges".
//
// This file proves:
//
//   - Lines always returns lines that follow the rules (IsLines), and only
//     one set of lines does (OnlyOneSetOfLines).
//   - The credits and the charges both sum to the effective cost, so a
//     dinner's lines sum to exactly zero, on every branch (LinesSumToZero).
//   - On a cancelled dinner, and on one with a total multiplier of 0,
//     every line is 0 (NothingMovesWhenNobodyIsCharged).
//   - No cook is credited more than they spent, or less than 0, and no
//     eater is charged less than 0 (CreditsAndCharges).
//   - Only a cancel, a total multiplier of 0, or a cap can make a dinner
//     subsidized (WhatMakesADinnerSubsidized).
//
// Amounts are whole units of 10^-8 dollars, and a cap is in units per
// unit of multiplier.
module MealLines {
  import opened Sums
  import opened Arithmetic
  import opened LargestRemainderSplit

  datatype Cap = NoCap | CapPerUnit(units: nat)

  // spent: what each cook spent, in order of resident id.
  // multipliers: each eater's multiplier, in tie-break order.
  datatype Dinner = Dinner(spent: seq<nat>, multipliers: seq<nat>, cap: Cap, cancelled: bool)

  function TotalCost(d: Dinner): int
  {
    Sum(d.spent)
  }

  function TotalMultiplier(d: Dinner): int
  {
    Sum(d.multipliers)
  }

  // Rule 2.
  function EffectiveCost(d: Dinner): nat
  {
    SumOfNats(d.spent);
    SumOfNats(d.multipliers);
    if d.cancelled then 0
    else if TotalMultiplier(d) == 0 then 0
    else match d.cap
      case NoCap => TotalCost(d)
      case CapPerUnit(units) =>
        MulKeepsOrder(units, 0, TotalMultiplier(d));
        if TotalCost(d) > units * TotalMultiplier(d) then units * TotalMultiplier(d) else TotalCost(d)
  }

  // Rule 3.
  predicate Subsidized(d: Dinner)
  {
    EffectiveCost(d) < TotalCost(d)
  }

  // The rules, as a test any credits and charges pass or fail. Rules 4
  // and 5. The two calls to SumOfNats show Dafny that both splits have
  // weights that sum to more than 0.
  predicate IsLines(d: Dinner, credits: seq<int>, charges: seq<int>)
  {
    SumOfNats(d.spent);
    SumOfNats(d.multipliers);
    && |credits| == |d.spent|
    && |charges| == |d.multipliers|
    && (if Subsidized(d)
        then IsSplit(EffectiveCost(d), d.spent, credits)
        else credits == d.spent)
    && (if TotalMultiplier(d) == 0
        then forall i :: 0 <= i < |charges| ==> charges[i] == 0
        else IsSplit(EffectiveCost(d), d.multipliers, charges))
  }

  // A sum of numbers that are not negative is not negative, and is 0 only
  // when every one of them is 0.
  lemma SumOfNats(s: seq<nat>)
    ensures Sum(s) >= 0
    ensures Sum(s) == 0 ==> forall i :: 0 <= i < |s| ==> s[i] == 0
  {
    var zeros := seq(|s|, i requires 0 <= i < |s| => 0);
    SumOfMultiples(s, 0, zeros);
    SumNoLarger(zeros, s);
  }

  // The effective cost is never negative and never more than the total
  // cost, and on a capped dinner never more than the cap allows.
  lemma EffectiveCostBounds(d: Dinner)
    ensures 0 <= EffectiveCost(d) <= TotalCost(d)
    ensures d.cap.CapPerUnit? ==> EffectiveCost(d) <= d.cap.units * TotalMultiplier(d)
    ensures Subsidized(d) ==> TotalCost(d) > 0
  {
    SumOfNats(d.spent);
    SumOfNats(d.multipliers);
    if d.cap.CapPerUnit? {
      MulKeepsOrder(d.cap.units, 0, TotalMultiplier(d));
    }
  }

  // The lines: rule 4 for the eaters, rule 5 for the cooks.
  method Lines(d: Dinner) returns (credits: seq<int>, charges: seq<int>)
    ensures IsLines(d, credits, charges)
  {
    EffectiveCostBounds(d);
    var effective: nat := EffectiveCost(d);

    if Subsidized(d) {
      credits := Split(effective, d.spent);
    } else {
      credits := d.spent;
    }

    if TotalMultiplier(d) == 0 {
      charges := seq(|d.multipliers|, i => 0);
    } else {
      SumOfNats(d.multipliers);
      charges := Split(effective, d.multipliers);
    }
  }

  // Only one set of lines follows the rules. So a program that follows
  // them on some dinner gives the same lines as Lines on that dinner.
  lemma OnlyOneSetOfLines(d: Dinner, credits: seq<int>, charges: seq<int>, credits': seq<int>, charges': seq<int>)
    requires IsLines(d, credits, charges) && IsLines(d, credits', charges')
    ensures credits == credits' && charges == charges'
  {
    EffectiveCostBounds(d);
    if Subsidized(d) {
      OnlyOneSplit(EffectiveCost(d), d.spent, credits, credits');
    }
    if TotalMultiplier(d) != 0 {
      SumOfNats(d.multipliers);
      OnlyOneSplit(EffectiveCost(d), d.multipliers, charges, charges');
    }
  }

  // The credits and the charges both sum to the effective cost, so the
  // dinner's lines (credits, and charges negated) sum to exactly zero.
  lemma LinesSumToZero(d: Dinner, credits: seq<int>, charges: seq<int>)
    requires IsLines(d, credits, charges)
    ensures Sum(credits) == EffectiveCost(d)
    ensures Sum(charges) == EffectiveCost(d)
    ensures Sum(credits) - Sum(charges) == 0
  {
    EffectiveCostBounds(d);
    if TotalMultiplier(d) == 0 {
      var zeros := seq(|charges|, i requires 0 <= i < |charges| => 0 * charges[i]);
      SumOfMultiples(charges, 0, zeros);
      assert zeros == charges;
    }
  }

  // A cancelled dinner, and one where the total multiplier is 0, move no
  // money: every credit and every charge is 0.
  lemma NothingMovesWhenNobodyIsCharged(d: Dinner, credits: seq<int>, charges: seq<int>)
    requires IsLines(d, credits, charges)
    requires d.cancelled || TotalMultiplier(d) == 0
    ensures forall i :: 0 <= i < |credits| ==> credits[i] == 0
    ensures forall i :: 0 <= i < |charges| ==> charges[i] == 0
  {
    EffectiveCostBounds(d);
    assert EffectiveCost(d) == 0;
    if Subsidized(d) {
      SplitOfZero(d.spent, credits);
    } else {
      SumOfNats(d.spent);
    }
    if TotalMultiplier(d) != 0 {
      SumOfNats(d.multipliers);
      SplitOfZero(d.multipliers, charges);
    }
  }

  // Splitting 0 gives 0 to everyone.
  lemma SplitOfZero(weights: seq<nat>, shares: seq<int>)
    requires Sum(weights) > 0
    requires IsSplit(0, weights, shares)
    ensures forall i :: 0 <= i < |shares| ==> shares[i] == 0
  {
    forall i | 0 <= i < |shares|
      ensures shares[i] == 0
    {
      assert Floors(0, weights)[i] == 0;
      assert Dropped(0, weights)[i] == 0;
    }
  }

  // Each share of a split is at least 0.
  lemma ShareNotNegative(total: nat, weights: seq<nat>, shares: seq<int>, i: int)
    requires Sum(weights) > 0
    requires IsSplit(total, weights, shares)
    requires 0 <= i < |shares|
    ensures shares[i] >= 0
  {
    var whole := Sum(weights);
    var x := total * weights[i];
    var floor := x / whole;
    assert Floors(total, weights)[i] == floor;
    assert shares[i] >= floor;
    MulKeepsOrder(total, 0, weights[i]);
    assert x >= 0;
    DivMod(x, whole);
    var r := x % whole;
    assert x == whole * floor + r && r < whole;
    // If floor were below 0, whole * floor would be at most -whole, and
    // x would be below 0.
    if floor < 0 {
      MulKeepsOrder(whole, floor, -1);
      assert whole * floor <= whole * -1;
      assert false;
    }
  }

  // When the amount split is less than the sum of the weights, no share is
  // more than its weight.
  lemma ShareAtMostWeight(total: nat, weights: seq<nat>, shares: seq<int>, i: int)
    requires Sum(weights) > 0
    requires total < Sum(weights)
    requires IsSplit(total, weights, shares)
    requires 0 <= i < |shares|
    ensures shares[i] <= weights[i]
  {
    var whole := Sum(weights);
    var w := weights[i];
    var x := total * w;
    var floor := Floors(total, weights)[i];
    var dropped := Dropped(total, weights)[i];
    DivMod(x, whole);
    assert x == whole * floor + dropped;
    if w == 0 {
      assert x == 0;
      MultipleHasNoRemainder(whole, 0);
      assert dropped == 0;
      assert shares[i] == floor;
      if floor > 0 {
        MulKeepsOrder(whole, 1, floor);
        assert false;
      }
      if floor < 0 {
        MulNegative(whole, floor);
        assert false;
      }
    } else {
      // whole * floor <= x = total * w <= (whole - 1) * w < whole * w,
      // so floor < w, and the share is at most floor + 1.
      MulKeepsOrder(w, total, whole - 1);
      assert x <= w * (whole - 1);
      MulOneLess(whole, w);
      assert x < whole * w;
      if floor >= w {
        MulKeepsOrder(whole, w, floor);
        assert false;
      }
    }
  }

  // No cook is credited more than they spent, or less than 0. No eater is
  // charged less than 0.
  lemma CreditsAndCharges(d: Dinner, credits: seq<int>, charges: seq<int>)
    requires IsLines(d, credits, charges)
    ensures forall i :: 0 <= i < |credits| ==> 0 <= credits[i] <= d.spent[i]
    ensures forall i :: 0 <= i < |charges| ==> charges[i] >= 0
  {
    EffectiveCostBounds(d);
    var effective: nat := EffectiveCost(d);
    forall i | 0 <= i < |credits|
      ensures 0 <= credits[i] <= d.spent[i]
    {
      if Subsidized(d) {
        ShareNotNegative(effective, d.spent, credits, i);
        ShareAtMostWeight(effective, d.spent, credits, i);
      }
    }
    forall i | 0 <= i < |charges|
      ensures charges[i] >= 0
    {
      if TotalMultiplier(d) != 0 {
        SumOfNats(d.multipliers);
        ShareNotNegative(effective, d.multipliers, charges, i);
      }
    }
  }

  // A dinner that is not cancelled, has someone to charge, and whose cost
  // is within its cap (or has no cap) is not subsidized: each cook is
  // credited exactly what they spent, and the eaters are charged the
  // total cost.
  lemma WhatMakesADinnerSubsidized(d: Dinner, credits: seq<int>, charges: seq<int>)
    requires IsLines(d, credits, charges)
    requires !d.cancelled && TotalMultiplier(d) != 0
    requires d.cap.NoCap? || TotalCost(d) <= d.cap.units * TotalMultiplier(d)
    ensures !Subsidized(d)
    ensures credits == d.spent
    ensures Sum(charges) == TotalCost(d)
  {
    LinesSumToZero(d, credits, charges);
  }

  // Worked examples, from the rules and MODELS.md. A proof shows that
  // Lines follows IsLines, but not that IsLines says what the rules say.
  // These pin IsLines to answers worked out by hand. Since only one set of
  // lines follows the rules (OnlyOneSetOfLines), each one is the only
  // answer for its dinner.

  // MODELS.md, "The Multiplier System": a $60 dinner, three adults and a
  // half-price child, no cap. The cook is credited $60, and the eaters
  // are charged the $60 split by multiplier.
  lemma SixtyDollarDinner()
    ensures IsLines(
              Dinner([6000000000], [2, 2, 2, 1], NoCap, false),
              [6000000000],
              [1714285715, 1714285714, 1714285714, 857142857])
  {
    var d := Dinner([6000000000], [2, 2, 2, 1], NoCap, false);
    SumOfFour(6000000000, 0, 0, 0);
    SumOfFour(2, 2, 2, 1);
    assert TotalCost(d) == 6000000000 && TotalMultiplier(d) == 7;
    assert EffectiveCost(d) == 6000000000;
    SixtyDollarsAcrossThreeAdultsAndAChild();
  }

  // Two cooks spent $40 and $20. Three adults ate, and the cap is $3 per
  // unit of multiplier, so the eaters are charged for $18 ($6 each), and
  // the cooks share the $18 by what they spent: $12 and $6.
  lemma CappedDinner()
    ensures IsLines(
              Dinner([4000000000, 2000000000], [2, 2, 2], CapPerUnit(300000000), false),
              [1200000000, 600000000],
              [600000000, 600000000, 600000000])
  {
    var d := Dinner([4000000000, 2000000000], [2, 2, 2], CapPerUnit(300000000), false);
    SumOfFour(4000000000, 2000000000, 0, 0);
    SumOfFour(2, 2, 2, 0);
    SumOfFour(1200000000, 600000000, 0, 0);
    SumOfFour(600000000, 600000000, 600000000, 0);
    assert TotalCost(d) == 6000000000 && TotalMultiplier(d) == 6;
    assert EffectiveCost(d) == 1800000000;
    assert Floors(1800000000, d.spent) == [1200000000, 600000000];
    assert Dropped(1800000000, d.spent) == [0, 0];
    assert Floors(1800000000, d.multipliers) == [600000000, 600000000, 600000000];
    assert Dropped(1800000000, d.multipliers) == [0, 0, 0];
  }

  // Three cooks spent $10 each. Three adults and a half-price child ate,
  // and the cap is $1 per unit, so the eaters are charged for $7. The
  // cooks share $7 three ways: $2.33333333 each and one unit left over,
  // which goes to the first cook (a tie, so the earlier position).
  lemma CappedDinnerWithATie()
    ensures IsLines(
              Dinner([1000000000, 1000000000, 1000000000], [2, 2, 2, 1], CapPerUnit(100000000), false),
              [233333334, 233333333, 233333333],
              [200000000, 200000000, 200000000, 100000000])
  {
    var d := Dinner([1000000000, 1000000000, 1000000000], [2, 2, 2, 1], CapPerUnit(100000000), false);
    SumOfFour(1000000000, 1000000000, 1000000000, 0);
    SumOfFour(2, 2, 2, 1);
    SumOfFour(233333334, 233333333, 233333333, 0);
    SumOfFour(200000000, 200000000, 200000000, 100000000);
    assert TotalCost(d) == 3000000000 && TotalMultiplier(d) == 7;
    assert EffectiveCost(d) == 700000000;
    assert Floors(700000000, d.spent) == [233333333, 233333333, 233333333];
    assert Dropped(700000000, d.spent) == [1000000000, 1000000000, 1000000000];
    assert Floors(700000000, d.multipliers) == [200000000, 200000000, 200000000, 100000000];
    assert Dropped(700000000, d.multipliers) == [0, 0, 0, 0];
  }

  // A cap the cost stays under changes nothing.
  lemma CapNotReached()
    ensures IsLines(
              Dinner([1000000000], [2, 2], CapPerUnit(300000000), false),
              [1000000000],
              [500000000, 500000000])
  {
    var d := Dinner([1000000000], [2, 2], CapPerUnit(300000000), false);
    SumOfFour(1000000000, 0, 0, 0);
    SumOfFour(2, 2, 0, 0);
    SumOfFour(500000000, 500000000, 0, 0);
    assert TotalCost(d) == 1000000000 && TotalMultiplier(d) == 4;
    assert EffectiveCost(d) == 1000000000;
    assert Floors(1000000000, d.multipliers) == [500000000, 500000000];
    assert Dropped(1000000000, d.multipliers) == [0, 0];
  }

  // Only free children ate: nobody can be charged. The cook spent $20 and
  // is credited $0, and the dinner is subsidized.
  lemma OnlyFreeEaters()
    ensures Subsidized(Dinner([2000000000], [0, 0], NoCap, false))
    ensures IsLines(Dinner([2000000000], [0, 0], NoCap, false), [0], [0, 0])
  {
    var d := Dinner([2000000000], [0, 0], NoCap, false);
    SumOfFour(2000000000, 0, 0, 0);
    SumOfFour(0, 0, 0, 0);
    assert TotalCost(d) == 2000000000 && TotalMultiplier(d) == 0;
    assert EffectiveCost(d) == 0;
    assert Floors(0, d.spent) == [0];
    assert Dropped(0, d.spent) == [0];
  }

  // A cancelled dinner charges nobody, whoever signed up. Its cook has $0
  // on the bill (a dinner with money on a bill cannot be cancelled).
  lemma CancelledDinner()
    ensures IsLines(Dinner([0], [2, 1], NoCap, true), [0], [0, 0])
  {
    var d := Dinner([0], [2, 1], NoCap, true);
    SumOfFour(0, 0, 0, 0);
    SumOfFour(2, 1, 0, 0);
    assert TotalCost(d) == 0 && TotalMultiplier(d) == 3;
    assert EffectiveCost(d) == 0;
    assert Floors(0, d.multipliers) == [0, 0];
    assert Dropped(0, d.multipliers) == [0, 0];
  }
}
