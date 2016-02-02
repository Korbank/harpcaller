#!/usr/bin/python

#-----------------------------------------------------------------------------

class Procedure(object):
    def __init__(self, function):
        self.function = function

    def __call__(self, *args, **kwargs):
        return self.function(*args, **kwargs)

def procedure(function):
    # the function could be simply `procedure = Procedure', but this way is
    # more readable
    return Procedure(function)

#-----------------------------------------------------------------------------

class StreamingProcedure(Procedure):
    def result(self):
        # method to be replaced by a subclass, so the procedure can return
        # stream and a value at the same time
        return None

def streaming_procedure(function):
    # the function could be simply `streamed = StreamingProcedure', but this
    # way is more readable
    return StreamingProcedure(function)

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
