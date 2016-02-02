#!/usr/bin/python

#-----------------------------------------------------------------------------
# decorator for streaming results {{{

class StreamedResult(object):
    def __init__(self, function):
        self.function = function

    def __call__(self, *args, **kwargs):
        return self.function(*args, **kwargs)

    def result(self):
        # method to be replaced by a subclass, so the procedure can return
        # stream and a value at the same time
        return None

def streamed(function):
    # the function could be simply `streamed = StreamedResult', but this way
    # is more readable
    return StreamedResult(function)

# }}}
#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
