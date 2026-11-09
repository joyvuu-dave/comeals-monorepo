// Small facts about multiplying and dividing whole numbers. Z3 often
// cannot find these on its own inside a larger proof, so the proofs call
// them one step at a time.
module Arithmetic {
  // A whole number is its quotient times the divisor, plus what is left.
  lemma DivMod(x: int, y: int)
    requires y > 0
    ensures x == y * (x / y) + x % y
    ensures 0 <= x % y < y
  {
  }

  lemma MulOneMore(a: int, w: int)
    ensures (a + 1) * w == a * w + w
  {
  }

  lemma MulOneLess(w: int, a: int)
    ensures (w - 1) * a == w * a - a
  {
  }

  lemma MulDifference(w: int, a: int, b: int)
    ensures w * a - w * b == w * (a - b)
  {
  }

  // Multiplying by a number that is not negative keeps the order.
  lemma MulKeepsOrder(w: int, a: int, b: int)
    requires w >= 0 && a <= b
    ensures w * a <= w * b
  {
  }

  // A positive number times a negative one is negative.
  lemma MulNegative(w: int, a: int)
    requires w > 0 && a < 0
    ensures w * a < 0
  {
  }
}
