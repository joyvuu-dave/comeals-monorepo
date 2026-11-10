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
import LargestRemainderSplit as LargestRemainderSplit

# Module: MealLines

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def TotalCost(d):
        return Sums.default__.Sum((d).spent)

    @staticmethod
    def TotalMultiplier(d):
        return Sums.default__.Sum((d).multipliers)

    @staticmethod
    def EffectiveCost(d):
        if (d).cancelled:
            return 0
        elif (default__.TotalMultiplier(d)) == (0):
            return 0
        elif True:
            source0_ = (d).cap
            if True:
                if source0_.is_NoCap:
                    return default__.TotalCost(d)
            if True:
                d_0_units_ = source0_.units
                if (default__.TotalCost(d)) > ((d_0_units_) * (default__.TotalMultiplier(d))):
                    return (d_0_units_) * (default__.TotalMultiplier(d))
                elif True:
                    return default__.TotalCost(d)

    @staticmethod
    def Subsidized(d):
        return (default__.EffectiveCost(d)) < (default__.TotalCost(d))

    @staticmethod
    def IsLines(d, credits, charges):
        def lambda0_(forall_var_0_):
            d_0_i_: int = forall_var_0_
            return not (((0) <= (d_0_i_)) and ((d_0_i_) < (len(charges)))) or (((charges)[d_0_i_]) == (0))

        return ((((len(credits)) == (len((d).spent))) and ((len(charges)) == (len((d).multipliers)))) and ((LargestRemainderSplit.default__.IsSplit(default__.EffectiveCost(d), (d).spent, credits) if default__.Subsidized(d) else (credits) == ((d).spent)))) and ((_dafny.quantifier(_dafny.IntegerRange(0, len(charges)), True, lambda0_) if (default__.TotalMultiplier(d)) == (0) else LargestRemainderSplit.default__.IsSplit(default__.EffectiveCost(d), (d).multipliers, charges)))

    @staticmethod
    def Lines(d):
        credits: _dafny.Seq = _dafny.Seq({})
        charges: _dafny.Seq = _dafny.Seq({})
        d_0_effective_: int
        d_0_effective_ = default__.EffectiveCost(d)
        if default__.Subsidized(d):
            out0_: _dafny.Seq
            out0_ = LargestRemainderSplit.default__.Split(d_0_effective_, (d).spent)
            credits = out0_
        elif True:
            credits = (d).spent
        if (default__.TotalMultiplier(d)) == (0):
            charges = _dafny.SeqWithoutIsStrInference([0 for d_1_i_ in range(len((d).multipliers))])
        elif True:
            out1_: _dafny.Seq
            out1_ = LargestRemainderSplit.default__.Split(d_0_effective_, (d).multipliers)
            charges = out1_
        return credits, charges


class Cap:
    @classmethod
    def default(cls, ):
        return lambda: Cap_NoCap()
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_NoCap(self) -> bool:
        return isinstance(self, Cap_NoCap)
    @property
    def is_CapPerUnit(self) -> bool:
        return isinstance(self, Cap_CapPerUnit)

class Cap_NoCap(Cap, NamedTuple('NoCap', [])):
    def __dafnystr__(self) -> str:
        return f'MealLines.Cap.NoCap'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Cap_NoCap)
    def __hash__(self) -> int:
        return super().__hash__()

class Cap_CapPerUnit(Cap, NamedTuple('CapPerUnit', [('units', Any)])):
    def __dafnystr__(self) -> str:
        return f'MealLines.Cap.CapPerUnit({_dafny.string_of(self.units)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Cap_CapPerUnit) and self.units == __o.units
    def __hash__(self) -> int:
        return super().__hash__()


class Dinner:
    @classmethod
    def default(cls, ):
        return lambda: Dinner_Dinner(_dafny.Seq({}), _dafny.Seq({}), Cap.default()(), False)
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Dinner(self) -> bool:
        return isinstance(self, Dinner_Dinner)

class Dinner_Dinner(Dinner, NamedTuple('Dinner', [('spent', Any), ('multipliers', Any), ('cap', Any), ('cancelled', Any)])):
    def __dafnystr__(self) -> str:
        return f'MealLines.Dinner.Dinner({_dafny.string_of(self.spent)}, {_dafny.string_of(self.multipliers)}, {_dafny.string_of(self.cap)}, {_dafny.string_of(self.cancelled)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Dinner_Dinner) and self.spent == __o.spent and self.multipliers == __o.multipliers and self.cap == __o.cap and self.cancelled == __o.cancelled
    def __hash__(self) -> int:
        return super().__hash__()

