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

# Module: TieOrder

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Less(a, b):
        return (((len(a)) > (0)) and ((len(b)) > (0))) and ((((a)[0]) < ((b)[0])) or ((((a)[0]) == ((b)[0])) and (default__.Less(_dafny.SeqWithoutIsStrInference((a)[1::]), _dafny.SeqWithoutIsStrInference((b)[1::])))))

    @staticmethod
    def Keyed(s, key, n):
        def lambda0_(forall_var_0_):
            d_0_i_: int = forall_var_0_
            return not (((0) <= (d_0_i_)) and ((d_0_i_) < (len(s)))) or ((len(key((s)[d_0_i_]))) == (n))

        def lambda1_(forall_var_1_):
            def lambda2_(forall_var_2_):
                d_2_j_: int = forall_var_2_
                return not ((((0) <= (d_1_i_)) and ((d_1_i_) < (d_2_j_))) and ((d_2_j_) < (len(s)))) or ((key((s)[d_1_i_])) != (key((s)[d_2_j_])))

            d_1_i_: int = forall_var_1_
            return _dafny.quantifier(_dafny.IntegerRange((d_1_i_) + (1), len(s)), True, lambda2_)

        return (_dafny.quantifier(_dafny.IntegerRange(0, len(s)), True, lambda0_)) and (_dafny.quantifier(_dafny.IntegerRange(0, len(s)), True, lambda1_))

    @staticmethod
    def Sorted(s, key):
        def lambda0_(forall_var_0_):
            def lambda1_(forall_var_1_):
                d_1_j_: int = forall_var_1_
                return not ((((0) <= (d_0_i_)) and ((d_0_i_) < (d_1_j_))) and ((d_1_j_) < (len(s)))) or (default__.Less(key((s)[d_0_i_]), key((s)[d_1_j_])))

            d_0_i_: int = forall_var_0_
            return _dafny.quantifier(_dafny.IntegerRange((d_0_i_) + (1), len(s)), True, lambda1_)

        return _dafny.quantifier(_dafny.IntegerRange(0, len(s)), True, lambda0_)

    @staticmethod
    def Sort(s, key):
        t: _dafny.Seq = _dafny.Seq({})
        t = _dafny.SeqWithoutIsStrInference([])
        d_0_i_: int
        d_0_i_ = 0
        while (d_0_i_) < (len(s)):
            d_1_x_: TypeVar('T__')
            d_1_x_ = (s)[d_0_i_]
            out0_: _dafny.Seq
            out0_ = default__.Insert(t, d_1_x_, key)
            t = out0_
            d_0_i_ = (d_0_i_) + (1)
        return t

    @staticmethod
    def Insert(t, x, key):
        u: _dafny.Seq = _dafny.Seq({})
        d_0_p_: int
        d_0_p_ = 0
        while ((d_0_p_) < (len(t))) and (not(default__.Less(key(x), key((t)[d_0_p_])))):
            d_0_p_ = (d_0_p_) + (1)
        u = ((_dafny.SeqWithoutIsStrInference((t)[:d_0_p_:])) + (_dafny.SeqWithoutIsStrInference([x]))) + (_dafny.SeqWithoutIsStrInference((t)[d_0_p_::]))
        return u

