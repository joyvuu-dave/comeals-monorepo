import sys
from typing import Callable, Any, TypeVar, NamedTuple
from math import floor
from itertools import count

import module_ as module_
import _dafny as _dafny
import System_ as System_
import Arithmetic as Arithmetic
import Sums as Sums
import LargestRemainder as LargestRemainder
import CentRounding as CentRounding
import TieOrder as TieOrder

# Module: LargestRemainderSplit

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Floors(total, weights):
        d_0_whole_ = Sums.default__.Sum(weights)
        return _dafny.SeqWithoutIsStrInference([_dafny.euclidian_division((total) * ((weights)[d_1_i_]), d_0_whole_) for d_1_i_ in range(len(weights))])

    @staticmethod
    def Dropped(total, weights):
        d_0_whole_ = Sums.default__.Sum(weights)
        return _dafny.SeqWithoutIsStrInference([_dafny.euclidian_modulus((total) * ((weights)[d_1_i_]), d_0_whole_) for d_1_i_ in range(len(weights))])

    @staticmethod
    def IsSplit(total, weights, shares):
        d_0_floors_ = default__.Floors(total, weights)
        d_1_dropped_ = default__.Dropped(total, weights)
        def lambda0_(forall_var_0_):
            d_2_i_: int = forall_var_0_
            return not (((0) <= (d_2_i_)) and ((d_2_i_) < (len(shares)))) or ((((shares)[d_2_i_]) == ((d_0_floors_)[d_2_i_])) or (((shares)[d_2_i_]) == (((d_0_floors_)[d_2_i_]) + (1))))

        def lambda1_(forall_var_1_):
            d_3_i_: int = forall_var_1_
            return not ((((0) <= (d_3_i_)) and ((d_3_i_) < (len(shares)))) and (((d_1_dropped_)[d_3_i_]) == (0))) or (((shares)[d_3_i_]) == ((d_0_floors_)[d_3_i_]))

        def lambda2_(forall_var_2_):
            def lambda3_(forall_var_3_):
                d_5_j_: int = forall_var_3_
                return not ((((((0) <= (d_4_i_)) and ((d_4_i_) < (len(shares)))) and (((0) <= (d_5_j_)) and ((d_5_j_) < (len(shares))))) and (((shares)[d_4_i_]) == (((d_0_floors_)[d_4_i_]) + (1)))) and (((shares)[d_5_j_]) == ((d_0_floors_)[d_5_j_]))) or (LargestRemainder.default__.Before(d_1_dropped_, d_4_i_, d_5_j_))

            d_4_i_: int = forall_var_2_
            return _dafny.quantifier(_dafny.IntegerRange(0, len(shares)), True, lambda3_)

        return (((((len(shares)) == (len(weights))) and ((Sums.default__.Sum(shares)) == (total))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(shares)), True, lambda0_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(shares)), True, lambda1_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(shares)), True, lambda2_))

    @staticmethod
    def Split(total, weights):
        shares: _dafny.Seq = _dafny.Seq({})
        d_0_n_: int
        d_0_n_ = len(weights)
        d_1_floors_: _dafny.Seq
        d_1_floors_ = default__.Floors(total, weights)
        d_2_dropped_: _dafny.Seq
        d_2_dropped_ = default__.Dropped(total, weights)
        d_3_leftover_: int
        d_3_leftover_ = (total) - (Sums.default__.Sum(d_1_floors_))
        d_4_got_: _dafny.Seq
        out0_: _dafny.Seq
        out0_ = LargestRemainder.default__.HandOut(d_2_dropped_, d_3_leftover_)
        d_4_got_ = out0_
        shares = _dafny.SeqWithoutIsStrInference([((d_1_floors_)[d_5_i_]) + ((d_4_got_)[d_5_i_]) for d_5_i_ in range(d_0_n_)])
        return shares

