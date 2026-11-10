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
import MealLines as MealLines

# Module: EntryPoints

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def NoneNegative(s):
        def lambda0_(forall_var_0_):
            d_0_i_: int = forall_var_0_
            return not (((0) <= (d_0_i_)) and ((d_0_i_) < (len(s)))) or (((s)[d_0_i_]) >= (0))

        return _dafny.quantifier(_dafny.IntegerRange(0, len(s)), True, lambda0_)

    @staticmethod
    def Split(total, weights):
        r: Answer = Answer.default()()
        if (((total) < (0)) or (not(default__.NoneNegative(weights)))) or ((Sums.default__.Sum(weights)) == (0)):
            r = Answer_Refused()
            return r
        d_0_shares_: _dafny.Seq
        out0_: _dafny.Seq
        out0_ = LargestRemainderSplit.default__.Split(total, weights)
        d_0_shares_ = out0_
        r = Answer_Answered(d_0_shares_)
        return r
        return r

    @staticmethod
    def BalanceKey(b):
        return _dafny.SeqWithoutIsStrInference([(b).id_])

    @staticmethod
    def Units(s):
        return _dafny.SeqWithoutIsStrInference([((s)[d_0_i_]).units for d_0_i_ in range(len(s))])

    @staticmethod
    def Ids(s):
        return _dafny.SeqWithoutIsStrInference([((s)[d_0_i_]).id_ for d_0_i_ in range(len(s))])

    @staticmethod
    def Round(cent, rows):
        r: Answer = Answer.default()()
        if ((cent) <= (0)) or (not(TieOrder.default__.Keyed(rows, default__.BalanceKey, 1))):
            rhs0_ = Answer_Refused()
            r = rhs0_
            return r
        d_0_ordered_: _dafny.Seq
        out0_: _dafny.Seq
        out0_ = TieOrder.default__.Sort(rows, default__.BalanceKey)
        d_0_ordered_ = out0_
        if (Sums.default__.Sum(default__.Units(d_0_ordered_))) != (0):
            rhs1_ = Answer_Refused()
            r = rhs1_
            return r
        d_1_out_: _dafny.Seq
        out1_: _dafny.Seq
        out1_ = CentRounding.default__.Round(cent, default__.Units(d_0_ordered_))
        d_1_out_ = out1_
        d_2_rounded_: _dafny.Seq
        d_2_rounded_ = _dafny.SeqWithoutIsStrInference([Balance_Balance(((d_0_ordered_)[d_3_i_]).id_, (d_1_out_)[d_3_i_]) for d_3_i_ in range(len(d_0_ordered_))])
        rhs2_ = Answer_Answered(d_2_rounded_)
        r = rhs2_
        return r
        return r

    @staticmethod
    def CookKey(c):
        return _dafny.SeqWithoutIsStrInference([(c).residentId])

    @staticmethod
    def EaterKey(e):
        return _dafny.SeqWithoutIsStrInference([(e).residentId, (1 if (e).guest else 0), (e).rowId])

    @staticmethod
    def Paid(s):
        d_0___accumulator_ = _dafny.SeqWithoutIsStrInference([])
        while True:
            with _dafny.label():
                if (len(s)) == (0):
                    return (d_0___accumulator_) + (_dafny.SeqWithoutIsStrInference([]))
                elif True:
                    d_0___accumulator_ = (d_0___accumulator_) + ((_dafny.SeqWithoutIsStrInference([]) if ((s)[0]).noCost else _dafny.SeqWithoutIsStrInference([(s)[0]])))
                    in0_ = _dafny.SeqWithoutIsStrInference((s)[1::])
                    s = in0_
                    raise _dafny.TailCall()
                break

    @staticmethod
    def Spent(s):
        return _dafny.SeqWithoutIsStrInference([((s)[d_0_i_]).spent for d_0_i_ in range(len(s))])

    @staticmethod
    def Multipliers(s):
        return _dafny.SeqWithoutIsStrInference([((s)[d_0_i_]).multiplier for d_0_i_ in range(len(s))])

    @staticmethod
    def DinnerOf(cooks, eaters, hasCap, cap, cancelled):
        return MealLines.Dinner_Dinner(default__.Spent(cooks), default__.Multipliers(eaters), (MealLines.Cap_CapPerUnit(cap) if hasCap else MealLines.Cap_NoCap()), cancelled)

    @staticmethod
    def Dinner(cooks, eaters, hasCap, cap, cancelled):
        r: Answer = Answer.default()()
        d_0_paid_: _dafny.Seq
        d_0_paid_ = default__.Paid(cooks)
        if ((not(TieOrder.default__.Keyed(d_0_paid_, default__.CookKey, 1))) or (not(TieOrder.default__.Keyed(eaters, default__.EaterKey, 3)))) or ((cap) < (0)):
            r = Answer_Refused()
            return r
        d_1_sortedCooks_: _dafny.Seq
        out0_: _dafny.Seq
        out0_ = TieOrder.default__.Sort(d_0_paid_, default__.CookKey)
        d_1_sortedCooks_ = out0_
        d_2_sortedEaters_: _dafny.Seq
        out1_: _dafny.Seq
        out1_ = TieOrder.default__.Sort(eaters, default__.EaterKey)
        d_2_sortedEaters_ = out1_
        if (not(default__.NoneNegative(default__.Spent(d_1_sortedCooks_)))) or (not(default__.NoneNegative(default__.Multipliers(d_2_sortedEaters_)))):
            r = Answer_Refused()
            return r
        d_3_credits_: _dafny.Seq
        d_4_charges_: _dafny.Seq
        out2_: _dafny.Seq
        out3_: _dafny.Seq
        out2_, out3_ = MealLines.default__.Lines(default__.DinnerOf(d_1_sortedCooks_, d_2_sortedEaters_, hasCap, cap, cancelled))
        d_3_credits_ = out2_
        d_4_charges_ = out3_
        r = Answer_Answered(Lines_Lines(d_1_sortedCooks_, d_3_credits_, d_2_sortedEaters_, d_4_charges_))
        return r
        return r


class Answer:
    @classmethod
    def default(cls, ):
        return lambda: Answer_Refused()
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Refused(self) -> bool:
        return isinstance(self, Answer_Refused)
    @property
    def is_Answered(self) -> bool:
        return isinstance(self, Answer_Answered)

class Answer_Refused(Answer, NamedTuple('Refused', [])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Answer.Refused'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Answer_Refused)
    def __hash__(self) -> int:
        return super().__hash__()

class Answer_Answered(Answer, NamedTuple('Answered', [('value', Any)])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Answer.Answered({_dafny.string_of(self.value)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Answer_Answered) and self.value == __o.value
    def __hash__(self) -> int:
        return super().__hash__()


class Balance:
    @classmethod
    def default(cls, ):
        return lambda: Balance_Balance(int(0), int(0))
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Balance(self) -> bool:
        return isinstance(self, Balance_Balance)

class Balance_Balance(Balance, NamedTuple('Balance', [('id_', Any), ('units', Any)])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Balance.Balance({_dafny.string_of(self.id_)}, {_dafny.string_of(self.units)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Balance_Balance) and self.id_ == __o.id_ and self.units == __o.units
    def __hash__(self) -> int:
        return super().__hash__()


class Cook:
    @classmethod
    def default(cls, ):
        return lambda: Cook_Cook(int(0), int(0), False)
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Cook(self) -> bool:
        return isinstance(self, Cook_Cook)

class Cook_Cook(Cook, NamedTuple('Cook', [('residentId', Any), ('spent', Any), ('noCost', Any)])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Cook.Cook({_dafny.string_of(self.residentId)}, {_dafny.string_of(self.spent)}, {_dafny.string_of(self.noCost)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Cook_Cook) and self.residentId == __o.residentId and self.spent == __o.spent and self.noCost == __o.noCost
    def __hash__(self) -> int:
        return super().__hash__()


class Eater:
    @classmethod
    def default(cls, ):
        return lambda: Eater_Eater(int(0), False, int(0), int(0))
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Eater(self) -> bool:
        return isinstance(self, Eater_Eater)

class Eater_Eater(Eater, NamedTuple('Eater', [('residentId', Any), ('guest', Any), ('rowId', Any), ('multiplier', Any)])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Eater.Eater({_dafny.string_of(self.residentId)}, {_dafny.string_of(self.guest)}, {_dafny.string_of(self.rowId)}, {_dafny.string_of(self.multiplier)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Eater_Eater) and self.residentId == __o.residentId and self.guest == __o.guest and self.rowId == __o.rowId and self.multiplier == __o.multiplier
    def __hash__(self) -> int:
        return super().__hash__()


class Lines:
    @classmethod
    def default(cls, ):
        return lambda: Lines_Lines(_dafny.Seq({}), _dafny.Seq({}), _dafny.Seq({}), _dafny.Seq({}))
    def __ne__(self, __o: object) -> bool:
        return not self.__eq__(__o)
    @property
    def is_Lines(self) -> bool:
        return isinstance(self, Lines_Lines)

class Lines_Lines(Lines, NamedTuple('Lines', [('cooks', Any), ('credits', Any), ('eaters', Any), ('charges', Any)])):
    def __dafnystr__(self) -> str:
        return f'EntryPoints.Lines.Lines({_dafny.string_of(self.cooks)}, {_dafny.string_of(self.credits)}, {_dafny.string_of(self.eaters)}, {_dafny.string_of(self.charges)})'
    def __eq__(self, __o: object) -> bool:
        return isinstance(__o, Lines_Lines) and self.cooks == __o.cooks and self.credits == __o.credits and self.eaters == __o.eaters and self.charges == __o.charges
    def __hash__(self) -> int:
        return super().__hash__()

