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

# Module: CentRounding

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Abs(x):
        if (x) < (0):
            return (0) - (x)
        elif True:
            return x

    @staticmethod
    def CutCent(cent, balance):
        if (balance) >= (0):
            return _dafny.euclidian_division(balance, cent)
        elif True:
            return (0) - (_dafny.euclidian_division((0) - (balance), cent))

    @staticmethod
    def CutCents(cent, balances):
        return _dafny.SeqWithoutIsStrInference([default__.CutCent(cent, (balances)[d_0_i_]) for d_0_i_ in range(len(balances))])

    @staticmethod
    def Cuts(cent, balances):
        return _dafny.SeqWithoutIsStrInference([(cent) * (default__.CutCent(cent, (balances)[d_0_i_])) for d_0_i_ in range(len(balances))])

    @staticmethod
    def Lost(cent, balances):
        return _dafny.SeqWithoutIsStrInference([((balances)[d_0_i_]) - ((cent) * (default__.CutCent(cent, (balances)[d_0_i_]))) for d_0_i_ in range(len(balances))])

    @staticmethod
    def IsRounding(cent, balances, out):
        d_0_cuts_ = default__.Cuts(cent, balances)
        d_1_lost_ = default__.Lost(cent, balances)
        def lambda0_(forall_var_0_):
            d_2_i_: int = forall_var_0_
            return not (((0) <= (d_2_i_)) and ((d_2_i_) < (len(out)))) or (((((out)[d_2_i_]) == ((d_0_cuts_)[d_2_i_])) or ((((out)[d_2_i_]) == (((d_0_cuts_)[d_2_i_]) - (cent))) and (((d_1_lost_)[d_2_i_]) < (0)))) or ((((out)[d_2_i_]) == (((d_0_cuts_)[d_2_i_]) + (cent))) and (((d_1_lost_)[d_2_i_]) > (0))))

        def lambda1_(forall_var_1_):
            def lambda2_(forall_var_2_):
                d_4_j_: int = forall_var_2_
                return not (((((0) <= (d_3_i_)) and ((d_3_i_) < (len(out)))) and (((0) <= (d_4_j_)) and ((d_4_j_) < (len(out))))) and (((out)[d_3_i_]) < ((d_0_cuts_)[d_3_i_]))) or (((out)[d_4_j_]) <= ((d_0_cuts_)[d_4_j_]))

            d_3_i_: int = forall_var_1_
            return _dafny.quantifier(_dafny.IntegerRange(0, len(out)), True, lambda2_)

        def lambda3_(forall_var_3_):
            def lambda4_(forall_var_4_):
                d_6_j_: int = forall_var_4_
                return not ((((((((0) <= (d_5_i_)) and ((d_5_i_) < (len(out)))) and (((0) <= (d_6_j_)) and ((d_6_j_) < (len(out))))) and (((out)[d_5_i_]) != ((d_0_cuts_)[d_5_i_]))) and (((out)[d_6_j_]) == ((d_0_cuts_)[d_6_j_]))) and (((d_1_lost_)[d_6_j_]) != (0))) and ((((d_1_lost_)[d_5_i_]) < (0)) == (((d_1_lost_)[d_6_j_]) < (0)))) or (((default__.Abs((d_1_lost_)[d_5_i_])) > (default__.Abs((d_1_lost_)[d_6_j_]))) or (((default__.Abs((d_1_lost_)[d_5_i_])) == (default__.Abs((d_1_lost_)[d_6_j_]))) and ((d_5_i_) < (d_6_j_))))

            d_5_i_: int = forall_var_3_
            return _dafny.quantifier(_dafny.IntegerRange(0, len(out)), True, lambda4_)

        return (((((len(out)) == (len(balances))) and ((Sums.default__.Sum(out)) == (0))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(out)), True, lambda0_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(out)), True, lambda1_))) and (_dafny.quantifier(_dafny.IntegerRange(0, len(out)), True, lambda3_))

    @staticmethod
    def Leftover(cent, balances):
        return Sums.default__.Sum(default__.CutCents(cent, balances))

    @staticmethod
    def Direction(cent, balances):
        if (default__.Leftover(cent, balances)) >= (0):
            return -1
        elif True:
            return 1

    @staticmethod
    def Key(cent, balances):
        d_0_direction_ = default__.Direction(cent, balances)
        return _dafny.SeqWithoutIsStrInference([(d_0_direction_) * (((balances)[d_1_i_]) - ((cent) * (default__.CutCent(cent, (balances)[d_1_i_])))) for d_1_i_ in range(len(balances))])

    @staticmethod
    def Round(cent, balances):
        out: _dafny.Seq = _dafny.Seq({})
        d_0_got_: _dafny.Seq
        out0_: _dafny.Seq
        out0_ = LargestRemainder.default__.HandOut(default__.Key(cent, balances), default__.Abs(default__.Leftover(cent, balances)))
        d_0_got_ = out0_
        out = default__.Build(cent, balances, d_0_got_)
        return out

    @staticmethod
    def Build(cent, balances, got):
        d_0_direction_ = default__.Direction(cent, balances)
        return _dafny.SeqWithoutIsStrInference([((cent) * (default__.CutCent(cent, (balances)[d_1_i_])) if ((got)[d_1_i_]) == (0) else (((cent) * (default__.CutCent(cent, (balances)[d_1_i_]))) - (cent) if (d_0_direction_) == (-1) else ((cent) * (default__.CutCent(cent, (balances)[d_1_i_]))) + (cent))) for d_1_i_ in range(len(got))])

    @staticmethod
    def Moved(cent, balances, out):
        return _dafny.SeqWithoutIsStrInference([(1 if ((out)[d_0_i_]) != ((default__.Cuts(cent, balances))[d_0_i_]) else 0) for d_0_i_ in range(len(out))])

