#!/usr/bin/python
'''
Interface for published procedures
----------------------------------

In simple cases, you may use decorators (:func:`procedure()` and
:func:`streaming_procedure()`) to mark function as a procedure intended for
remote calls. In more sophisticated cases, you may create a subclass of
:class:`Procedure` or :class:`StreamingProcedure`.

.. decorator:: procedure
.. decorator:: procedure(timeout = ..., uid = ..., gid = ...)

   Mark the function as a remote callable procedure.

   Whatever the function returns, it will be sent as a result.

   The second form allows to set options, like UID/GID to run as (either
   numeric or name) or time the function execution will take. Timeout will be
   signaled with a *SIGXCPU* signal (sensible default handler is provided).

   See :class:`Procedure`.

.. decorator:: streaming_procedure
.. decorator:: streaming_procedure(timeout = ..., uid = ..., gid = ...)

   Mark the function as a remote callable procedure that returns streamed
   result.

   Function produces the stream by using ``yield msg`` (i.e., by returning an
   iterator). To return a value, function should yield :class:`Result`
   object, which will be the last object consumed. If function does not yield
   :class:`Result`, reported returned value will be simply ``None``.

   The second form allows to set options, like UID/GID to run as (either
   numeric or name) or time the function execution will take. Timeout will be
   signaled with a *SIGXCPU* signal (sensible default handler is provided).

   See :class:`StreamingProcedure`, :class:`Result`.

Examples of using decorators::

    from harpd.proc import procedure, streaming_procedure, Result
    import time
    import subprocess
    import re

    _UPTIME_RE = re.compile(
        r'^..:..:.. up (.*),'
        r'  \d users?,'
        r'  load average: (\d\.\d\d), (\d\.\d\d), (\d\.\d\d)$'
    )

    @procedure
    def sum_and_difference(a, b):
        return {"sum": a + b, "difference": a - b}

    @procedure(uid = "nobody")
    def uptime():
        uptime_output = subprocess.check_output("uptime").strip()
        (uptime, load1, load5, load15) = _UPTIME_RE.match(uptime_output).groups()
        return {
            "uptime": uptime,
            "load average": { "1": load1, "5": load5, "15": load15 },
        }

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

   .. attribute:: function

      function to call

   .. attribute:: timeout

      time after which the process running the function will be terminated

   .. attribute:: uid

      UID or username to run the function as

   .. attribute:: gid

      GID or group name to run the function as

.. autoclass:: StreamingProcedure
   :members:
   :inherited-members:

   .. automethod:: __call__

   .. attribute:: function

      function to call

   .. attribute:: timeout

      time after which the process running the function will be terminated

   .. attribute:: uid

      UID or username to run the function as

   .. attribute:: gid

      GID or group name to run the function as

'''
#-----------------------------------------------------------------------------

class Procedure(object):
    '''
    :param function: function to wrap
    :type function: callable
    :param timeout: time after which *SIGXCPU* will be sent to the process
        executing the function
    :param uid: user to run the function as
    :param gid: group to run the function as

    Simple callable wrapper over a function.
    '''
    def __init__(self, function, timeout = None, uid = None, gid = None):
        self.function = function
        self.timeout = timeout
        self.uid = uid
        self.gid = gid
        self.__doc__ = function.__doc__

    def __call__(self, *args, **kwargs):
        '''
        :return: call result

        Execute the procedure and return its result.
        '''
        return self.function(*args, **kwargs)

def procedure(function = None, timeout = None, uid = None, gid = None):
    # NOTE: documented in module-level docstring
    def wrapper(function):
        return Procedure(function, timeout = timeout, uid = uid, gid = gid)

    if function is None:
        return wrapper
    else:
        return wrapper(function)

#-----------------------------------------------------------------------------

class StreamingProcedure(Procedure):
    '''
    :param function: function to wrap
    :type function: callable
    :param timeout: time after which *SIGXCPU* will be sent to the process
        executing the function
    :param uid: user to run the function as
    :param gid: group to run the function as

    Callable wrapper over a function that produces streamed response using
    ``yield``.
    '''

    def __init__(self, function, timeout = None, uid = None, gid = None):
        super(StreamingProcedure, self).__init__(function, timeout = None,
                                                 uid = None, gid = None)
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

def streaming_procedure(function = None, timeout = None,
                        uid = None, gid = None):
    # NOTE: documented in module-level docstring
    def wrapper(function):
        return StreamingProcedure(function, timeout = timeout,
                                  uid = uid, gid = gid)

    if function is None:
        return wrapper
    else:
        return wrapper(function)

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
