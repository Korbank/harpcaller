#!/usr/bin/python

from proc import streamed
import time

#-----------------------------------------------------------------------------
# stub for user-supplied procedures

def return_immediate(*args, **kwargs):
    if len(kwargs) > 0:
        return {
            "call_type": "kwargs",
            "args_count": len(kwargs),
            "delayed": False,
        }
    else:
        return {
            "call_type": "args",
            "args_count": len(args),
            "delayed": False,
        }

def return_delayed(*args, **kwargs):
    time.sleep(10)

    if len(kwargs) > 0:
        return {
            "call_type": "kwargs",
            "args_count": len(kwargs),
            "delayed": True,
        }
    else:
        return {
            "call_type": "args",
            "args_count": len(args),
            "delayed": True,
        }

@streamed
def stream_immediate(*args, **kwargs):
    for i in xrange(1, 10):
        yield {"packet": i, "letter": chr(ord('A') - 1 + i), "delayed": False}
        time.sleep(1)
    yield {"packet": i, "letter": chr(ord('a') - 1 + 10), "delayed": False}

@streamed
def stream_delayed(*args, **kwargs):
    time.sleep(10)
    for i in xrange(1, 10):
        yield {"packet": i, "letter": chr(ord('A') - 1 + i), "delayed": True}
        time.sleep(1)
    yield {"packet": i, "letter": chr(ord('a') - 1 + 10), "delayed": True}

@streamed
def stream_infinity(*args, **kwargs):
    time.sleep(5)
    while True:
        yield {"current_time": int(time.time())}
        time.sleep(1)

#-----------------------------------------------------------------------------

PROCEDURES = {
    "return_immediate": return_immediate,
    "return_delayed":   return_delayed,
    "stream_immediate": stream_immediate,
    "stream_delayed":   stream_delayed,
    "stream_infinity":  stream_infinity,
}

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
