#!/usr/bin/python
'''
Interface for published procedures
----------------------------------

In simple cases, you may use decorators (:func:`procedure()` and
:func:`streaming_procedure()`) to mark function as a procedure intended for
remote calls. In more sophisticated cases, you may create a subclass of
:class:`Procedure` or :class:`StreamingProcedure`.

.. decorator:: procedure

   Mark the function as a remote callable procedure.

   Whatever the function returns, it will be sent as a result.

   See :class:`Procedure`.

.. decorator:: streaming_procedure

   Mark the function as a remote callable procedure that returns streamed
   result.

   Function produces the stream by using ``yield msg`` (i.e., by returning an
   iterator). To return a value, function should yield :class:`Result`
   object, which will be the last object consumed. If function does not yield
   :class:`Result`, reported returned value will be simply ``None``.

   See :class:`StreamingProcedure`, :class:`Result`.

Examples of using decorators::

    @procedure
    def sum_and_difference(a, b):
        return {"sum": a + b, "difference": a - b}

    @streaming_procedure
    def stream():
        for i in xrange(1, 10):
            yield {"i": i}
            time.sleep(1)
        yield Result({"msg": "end of xrange"})

.. autoclass:: Result
   :members:

.. autoclass:: Procedure
   :members:

   .. automethod:: __call__

.. autoclass:: StreamingProcedure
   :members:

   .. automethod:: __call__

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
        '''
        :return: call result

        Execute the procedure and return its result.
        '''
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

    def __init__(self, function):
        super(StreamingProcedure, self).__init__(function)
        self._result = None

    def __call__(self, *args, **kwargs):
        '''
        :return: stream result
        :rtype: iterator

        Execute the procedure and return its streamed result as an iterator.
        To report returned value, use :meth:`result()`.
        '''
        for msg in self.function(*args, **kwargs):
            if isinstance(msg, Result):
                self._result = msg.value
                break
            yield msg

    def result(self):
        '''
        :return: call result

        Return the result that the procedure was supposed to return.
        '''
        return self._result

# XXX: promised decorator
streaming_procedure = StreamingProcedure

#-----------------------------------------------------------------------------

class Result(object):
    '''
    :param value: value to be returned

    Yield a message to be resulting value from :class:`StreamingProcedure`.
    '''
    def __init__(self, value):
        self.value = value

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
