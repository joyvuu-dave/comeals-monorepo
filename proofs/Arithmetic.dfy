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

  // Two products with the same positive factor are equal only when the
  // other factors are.
  lemma MulCancel(w: int, a: int, b: int)
    requires w > 0 && w * a == w * b
    ensures a == b
  {
    if a < b {
      MulKeepsOrder(w, a + 1, b);
      MulOneMore(a, w);
    } else if a > b {
      MulKeepsOrder(w, b + 1, a);
      MulOneMore(b, w);
    }
  }

  // A multiple of w leaves nothing when divided by w.
  lemma MultipleHasNoRemainder(w: int, m: int)
    requires w > 0
    ensures (w * m) % w == 0
  {
    DivMod(w * m, w);
    var q := (w * m) / w;
    var r := (w * m) % w;
    assert w * m == w * q + r;
    MulDifference(w, m, q);
    assert w * (m - q) == r;
    if m - q > 0 {
      MulKeepsOrder(w, 1, m - q);
    } else if m - q < 0 {
      MulNegative(w, m - q);
    }
  }

  lemma MulNegate(w: int, a: int)
    ensures w * (-a) == -(w * a)
    ensures (-w) * a == -(w * a)
  {
  }

  lemma MulAdd(w: int, a: int, b: int)
    ensures w * (a + b) == w * a + w * b
  {
  }
}
