#!/usr/bin/python
#
# RPC procedures exposed by harpd
#

from harpd.proc import procedure, streaming_procedure, Result
import time

#-----------------------------------------------------------------------------

@procedure
def sum_and_difference(a, b):
    return {"sum": a + b, "difference": a - b}

@streaming_procedure
def stream():
    for i in xrange(1, 10):
        yield {"i": i}
        time.sleep(1)
    yield Result({"msg": "end of xrange"})

#-----------------------------------------------------------------------------
# vim:ft=python
