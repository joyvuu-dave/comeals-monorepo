import sys
from typing import Callable, Any, TypeVar, NamedTuple
from math import floor
from itertools import count

import module_ as module_
import _dafny as _dafny
import System_ as System_
import Arithmetic as Arithmetic

# Module: Sums

class default__:
    def  __init__(self):
        pass

    @staticmethod
    def Sum(s):
        hresult_: int = int(0)
        d_0_total_: int
        d_0_total_ = 0
        d_1_i_: int
        d_1_i_ = 0
        while (d_1_i_) < (len(s)):
            d_0_total_ = (d_0_total_) + ((s)[d_1_i_])
            d_1_i_ = (d_1_i_) + (1)
        hresult_ = d_0_total_
        return hresult_
        return hresult_

