import sys
from typing import Callable, Any, TypeVar, NamedTuple
from math import floor
from itertools import count

import module_ as module_
import _dafny as _dafny
import System_ as System_
import Arithmetic as Arithmetic
import Sums as Sums

# Module: LargestRemainder

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Positive(key):
        return _dafny.SeqWithoutIsStrInference([(1 if ((key)[d_0_i_]) > (0) else 0) for d_0_i_ in range(len(key))])

    @staticmethod
    def Before(key, i, j):
        return (((key)[i]) > ((key)[j])) or ((((key)[i]) == ((key)[j])) and ((i) < (j)))

    @staticmethod
    def HandedOut(key, got):
        def lambda0_(forall_var_0_):
            d_0_i_: int = forall_var_0_
            return not (((0) <= (d_0_i_)) and ((d_0_i_) < (len(got)))) or ((((got)[d_0_i_]) == (0)) or (((got)[d_0_i_]) == (1)))

        def lambda1_(forall_var_1_):
            d_1_i_: int = forall_var_1_
            return not ((((0) <= (d_1_i_)) and ((d_1_i_) < (len(got)))) and (((got)[d_1_i_]) == (1))) or (((key)[d_1_i_]) > (0))

        def lambda2_(forall_var_2_):
            def lambda3_(forall_var_3_):
                d_3_j_: int = forall_var_3_
                return not ((((((0) <= (d_2_i_)) and ((d_2_i_) < (len(got)))) and (((0) <= (d_3_j_)) and ((d_3_j_) < (len(got))))) and (((got)[d_2_i_]) == (1))) and (((got)[d_3_j_]) == (0))) or (default__.Before(key, d_2_i_, d_3_j_))

            d_2_i_: int = forall_var_2_
            return _dafny.quantifier(_dafny.IntegerRange(0, len(got)), True, lambda3_)

        return ((((len(got)) == (len(key))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(got)), True, lambda0_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(got)), True, lambda1_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(got)), True, lambda2_))

    @staticmethod
    def First(got, key):
        best: int = int(0)
        best = -1
        d_0_i_: int
        d_0_i_ = 0
        while (d_0_i_) < (len(got)):
            if (((got)[d_0_i_]) == (0)) and (((best) == (-1)) or (default__.Before(key, d_0_i_, best))):
                best = d_0_i_
            d_0_i_ = (d_0_i_) + (1)
        return best

    @staticmethod
    def HandOut(key, k):
        got: _dafny.Seq = _dafny.Seq({})
        d_0_n_: int
        d_0_n_ = len(key)
        got = _dafny.SeqWithoutIsStrInference([0 for d_1_i_ in range(d_0_n_)])
        d_2_handed_: int
        d_2_handed_ = 0
        while (d_2_handed_) < (k):
            d_3_best_: int
            out0_: int
            out0_ = default__.First(got, key)
            d_3_best_ = out0_
            got = (got).set(d_3_best_, 1)
            d_2_handed_ = (d_2_handed_) + (1)
        return got

