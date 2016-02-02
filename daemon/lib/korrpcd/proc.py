#!/usr/bin/python
'''
Interface for published procedures
----------------------------------

.. decorator:: procedure

   Mark the function as a remote callable procedure.

   See :class:`Procedure`.

.. decorator:: streaming_procedure

   Mark the function as a remote callable procedure that returns streamed
   result.

   See :class:`StreamingProcedure`.

.. autoclass:: Procedure
   :members:

.. autoclass:: StreamingProcedure
   :members:

'''
#-----------------------------------------------------------------------------

class Procedure(object):
    '''
    :param function: function to wrap
    :type function: callable

    Simple callable wrapper over a function.
    '''
    def __init__(self, function):
        self.function = function

    def __call__(self, *args, **kwargs):
        return self.function(*args, **kwargs)

# XXX: promised decorator
procedure = Procedure

#-----------------------------------------------------------------------------

class StreamingProcedure(Procedure):
    '''
    :param function: function to wrap
    :type function: callable

    Callable wrapper over a function that produces streamed response using
    ``yield``.
    '''

    def result(self):
        '''
        :return: call result

        Return the result that the procedure was supposed to return.
        '''
        # method to be replaced by a subclass, so the procedure can return
        # stream and a value at the same time
        return None

# XXX: promised decorator
streaming_procedure = StreamingProcedure

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
