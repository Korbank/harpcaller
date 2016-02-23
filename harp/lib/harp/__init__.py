#!/usr/bin/python
'''
.. autoclass:: HarpCaller
   :members:

   .. automethod:: __getattr__

.. autoclass:: RemoteServer
   :members:

   .. automethod:: __call__

.. autoclass:: RemoteProcedure
   :members:

   .. automethod:: __call__

.. autoclass:: RemoteCall
   :members:

.. autoclass:: JSONConnection
   :members:

.. autodata:: CALL_NOT_FINISHED

.. autodata:: CALL_CANCELLED

.. autoexception:: HarpException
   :members:

.. autoexception:: CommunicationError
   :members:

.. autoexception:: CancelledException
   :members:

.. autoexception:: RemoteException
   :members:

.. autoexception:: RemoteError
   :members:

'''
#-----------------------------------------------------------------------------

import socket
import json

#-----------------------------------------------------------------------------

class CallNotFinished(object):
    def __repr__(self):
        return "<CallNotFinished>"

class CallCancelled(object):
    def __repr__(self):
        return "<CallCancelled>"

CALL_NOT_FINISHED = CallNotFinished()
'''
Value returned instead of RPC call result if the call is still running.
'''

CALL_CANCELLED = CallCancelled()
'''
Value returned as a result when RPC call was cancelled.
'''

#-----------------------------------------------------------------------------
# JSON connection reader {{{

class JSONConnection(object):
    '''
    TCP connection, reading and writing JSON lines.

    Object of this class is a valid context manager, so it can be used this
    way::

       with JSONConnection(host, port) as conn:
           conn.send({"key": "value"})
           reply = conn.receive()
    '''
    def __init__(self, host, port):
        '''
        :param host: address of dispatcher server
        :param port: port of dispatcher server
        '''
        self.host = host
        self.port = port
        self.sockf = None
        self.connect()

    def connect(self):
        '''
        Connect to the address specified in constructor.
        Newly created :class:`JSONConnection` objects are already connected.
        '''
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        try:
            s.connect((self.host, self.port))
            self.sockf = s.makefile()
            s.close()
        except socket.error, e:
            s.close()
            raise CommunicationError(
                "can't connect to %s:%s: %s" % (self.host, self.port, str(e))
            )

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def __del__(self):
        self.close()

    def close(self):
        '''
        Close connection. To connect again, use :meth:`connect()`.
        '''
        if self.sockf is not None:
            self.sockf.close()
        self.sockf = None

    def send(self, obj):
        '''
        :param obj: object serializable with :mod:`json` module

        Send an object as a JSON line.
        '''
        if self.sockf is None:
            raise CommunicationError("socket not connected")

        try:
            # buffered write, so I can skip string concatenation to get whole
            # line written at once
            self.sockf.write(json.dumps(obj))
            self.sockf.write("\n")
            self.sockf.flush()
        except socket.error, e:
            raise CommunicationError(
                "can't send to %s:%s: %s" % (self.host, self.port, str(e))
            )

    def receive(self):
        '''
        :return: object serializable with :mod:`json` module

        Receive JSON line and deserialize it, typically to a ``dict``.
        '''
        line = self.sockf.readline()
        if line == "":
            return None
        try:
            return json.loads(line)
        except ValueError, e:
            raise CommunicationError(str(e)) # invalid JSON object

# }}}
#-----------------------------------------------------------------------------
# exceptions {{{

class HarpException(Exception, object):
    '''
    Base class for all exceptions thrown in this module.
    '''
    pass

class CommunicationError(HarpException):
    '''
    Error in communication with dispatcher.
    '''
    pass

class CancelledException(HarpException):
    '''
    Exception thrown when job has no return value due to being cancelled.
    '''
    pass

class RemoteException(HarpException):
    '''
    Exception returned/thrown when the remote procedure threw an exception.

    Defined fields:

    .. attribute:: type (unicode)

       Identifier of error type.

    .. attribute:: message (unicode)

       Complete error message.

    .. attribute:: data

       Arbitrary JSON-serializable context information. ``None`` if nothing
       was provided by remote side.

    '''
    def __init__(self, type, message, data = None):
        super(RemoteException, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

class RemoteError(HarpException):
    '''
    Exception returned/thrown when dispatcher couldn't reach the target RPC
    server for some reason.

    Defined fields:

    .. attribute:: type (unicode)

       Identifier of error type.

    .. attribute:: message (unicode)

       Complete error message.

    .. attribute:: data

       Arbitrary JSON-serializable context information. ``None`` if nothing
       was provided by remote side.

    '''
    def __init__(self, type, message, data = None):
        super(RemoteError, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

# }}}
#-----------------------------------------------------------------------------
# HarpCaller {{{

class HarpCaller(object):
    '''
    Dispatcher server representation.
    '''
    def __init__(self, host, port = 3502):
        '''
        :param host: address of dispatcher
        :param port: port of dispatcher
        '''
        self._host = host
        self._port = port

    def job(self, job_id):
        '''
        :param job_id: call job identifier
        :type job_id: string
        :return: call job representation
        :rtype: :class:`RemoteCall`

        Get a job representation, to retrieve from dispatcher its result and
        other information.
        '''
        return RemoteCall(self, job_id)

    def connect(self):
        '''
        :return: connection to dispatcher server
        :rtype: :class:`JSONConnection`

        Connect to dispatcher server, to send a request and read a reply.
        '''
        return JSONConnection(self._host, self._port)

    def request(self, req):
        '''
        :param req: request to send to the dispatcher server
        :type req: dict
        :return: reply from the dispatcher server
        :rtype: dict

        Connect to dispatcher server, to send a request and read a reply.
        '''
        with self.connect() as conn:
            conn.send(req)
            response = conn.receive()
            if response is None:
                raise CommunicationError("unexpected EOF")
            return response

    def __getattr__(self, host):
        '''
        :return: target server representation
        :rtype: :class:`RemoteServer`

        Convenience method to get a statically-known host. Returned context is
        not configured with any job options. To change that, use
        :meth:`RemoteServer.__call__()`::

            rpc = HarpCaller("...")
            # get nginx' status on web01, no job configuration
            rpc.web01.nginx_status().get()
            # enqueue nginx restart request
            rpc.web01(queue = {"service": "nginx", "host": "web01"}) \\
               .restart_nginx()

        See also: :meth:`host()`.
        '''
        return self.host(host)

    def host(self, host, **kwargs):
        '''
        :param host: target RPC server
        :type host: string
        :param queue: name of a queue to wait in
        :type queue: dict
        :param concurrency: number of simultaneously running jobs in the queue
        :type concurrency: positive integer
        :param timeout: maximum time between consequent reads from the job
        :type timeout: positive integer (seconds)
        :param max_exec_time: maximum time the job is allowed to take
        :type max_exec_time: positive integer (seconds)
        :return: target server representation
        :rtype: :class:`RemoteServer`

        Prepare context (target and job options) for calling a remote
        procedure on a server.
        '''
        result = RemoteServer(self, host)
        result(**kwargs)
        return result

    def __repr__(self):
        return "<%s.%s %s:%d>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self._host,
            self._port,
        )

# }}}
#-----------------------------------------------------------------------------
# RemoteServer {{{

class RemoteServer(object):
    '''
    Target RPC server representation. This representation also carries
    options to be used for calling a remote procedure (timeout, maximum
    execution time, queue name, etc.).

    :param dispatcher: dispatcher instance
    :type dispatcher: :class:`HarpCaller`
    :param hostname: name of the target server

    See also :meth:`__call__()`.

    .. automethod:: __str__

    .. automethod:: __getattr__
    '''
    def __init__(self, dispatcher, hostname):
        self._dispatcher = dispatcher
        self._hostname = hostname
        self._queue = None
        self._concurrency = None
        self._timeout = None
        self._max_exec_time = None

    def __call__(self, **kwargs):
        '''
        :param queue: name of a queue to wait in
        :type queue: dict
        :param concurrency: number of simultaneously running jobs in the queue
        :type concurrency: positive integer
        :param timeout: maximum time between consequent reads from the job
        :type timeout: positive integer (seconds)
        :param max_exec_time: maximum time the job is allowed to take
        :type max_exec_time: positive integer (seconds)
        :return: :obj:`self`

        Adjust job options for this host.
        '''
        if "queue" in kwargs:
            self._queue = kwargs["queue"]
        if "concurrency" in kwargs:
            self._concurrency = kwargs["concurrency"]
        if "timeout" in kwargs:
            self._timeout = kwargs["timeout"]
        if "max_exec_time" in kwargs:
            self._max_exec_time = kwargs["max_exec_time"]
        return self

    def _call_options(self):
        result = {
            "queue": {
                "name": self._queue,
                "concurrency": self._concurrency,
            },
            "timeout": self._timeout,
            "max_exec_time": self._max_exec_time,
        }
        if result["queue"]["name"] is None:
            del result["queue"]
        elif result["queue"]["concurrency"] is None:
            del result["queue"]["concurrency"]
        if result["timeout"] is None:
            del result["timeout"]
        if result["max_exec_time"] is None:
            del result["max_exec_time"]
        return result

    def __getattr__(self, procedure):
        '''
        :return: remote procedure representation
        :rtype: :class:`RemoteProcedure`

        Any attribute of this object is a callable representation of a remote
        procedure. To submit a call request, one can use::

           rpc = HarpCaller(dispatcher_address)
           host = rpc.host("remote-server") # this is `RemoteServer' instance
           host.my_remote_function_name(arg1, arg2, ...)
        '''
        return RemoteProcedure(self._dispatcher, self, procedure)

    def __str__(self):
        '''
        Stringify to target hostname.
        '''
        return self._hostname

    def __repr__(self):
        return "<%s.%s %s>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self._hostname,
        )

# }}}
#-----------------------------------------------------------------------------
# RemoteProcedure {{{

class RemoteProcedure(object):
    '''
    Callable representation of a remote procedure.
    '''
    def __init__(self, dispatcher, server, procedure):
        '''
        :param dispatcher: dispatcher instance
        :type dispatcher: :class:`HarpCaller`
        :param server: remote server instance
        :type server: :class:`RemoteServer`
        :param procedure: name of the procedure to call
        :type procedure: string
        '''
        self._dispatcher = dispatcher
        self._server = server
        self._procedure = procedure

    def procedure(self):
        '''
        :return: name of procedure to call
        :rtype: string

        Retrieve name of the procedure that will be called.
        '''
        return self._procedure

    def host(self):
        '''
        :return: name of server to call this procedure at
        :rtype: string

        Retrieve host this procedure will be called on.
        '''
        return str(self._server)

    def __call__(self, *args, **kwargs):
        '''
        :return: call job handle
        :rtype: :class:`RemoteCall`

        Request a call to this procedure on target server to dispatcher.
        '''
        if len(args) == 0 and len(kwargs) > 0:
            call_args = kwargs
        elif len(kwargs) == 0:
            call_args = args

        request = {
            "harpcaller": 1,
            "host": str(self._server),
            "procedure": self._procedure,
            "arguments": call_args,
        }
        request.update(self._server._call_options())
        reply = self._dispatcher.request(request)

        return RemoteCall(self._dispatcher, reply["job_id"])

    def __repr__(self):
        return "<%s.%s %s:%s()>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.host(),
            self.procedure(),
        )

# }}}
#-----------------------------------------------------------------------------
# RemoteCall {{{

class RemoteCall(object):
    '''
    RPC call job representation. Allows to check job's status, retrieve its
    results (both streamed and returned), and to cancel if it's still running.
    '''

    #-------------------------------------------------------
    # StreamIterator {{{

    class StreamIterator(object):
        '''
        Iterator for call's streamed result.
        '''
        def __init__(self, remote_call, conn, numbered = False):
            '''
            :param remote_call: object representing a call to iterate through
            :type remote_call: :class:`RemoteCall`
            :param conn: connection to dispatcher server
            :type conn: :class:`JSONConnection`
            :param numbered: whether iteration should yield tuples for easy
                packet ID tracking
            :type numbered: bool
            '''
            self.remote_call = remote_call
            self.conn = conn
            self.numbered = numbered

        def __iter__(self):
            return self

        def next(self):
            packet = self.conn.receive()
            if packet is None or "packet" not in packet:
                self.conn.close()
                if packet is not None:
                    self.remote_call._remember_result(packet)
                raise StopIteration()
            if self.numbered:
                return (packet["packet"], packet["data"])
            else:
                return packet["data"]

        def all(self):
            '''
            :return: list of all packets this iterator would yield

            Retrieve all packets at once in a single list.
            '''
            return [packet for packet in self]

    # }}}
    #-------------------------------------------------------

    def __init__(self, dispatcher, job_id):
        '''
        :param dispatcher: dispatcher instance
        :type dispatcher: :class:`HarpCaller`
        :param job_id: call job identifier
        :type job_id: string
        '''
        self.dispatcher = dispatcher
        self.job_id = job_id
        self._result = None
        self._has_result = False

    def id(self):
        '''
        :rtype: string

        Return this job's identifier, so job's data can be recalled at some
        later time.
        '''
        return self.job_id

    def follow(self, since = None, recent = None, numbered = False):
        '''
        :param since: message number to read stream result from
        :type since: non-negative integer
        :param recent: number of messages before current to read stream result
            from
        :type recent: non-negative integer
        :param numbered: if ``True``, iterator will produce pairs ``(pktid,
            msg)``, with :obj:`pktid` having an analogous meaning to
            :obj:`since`
        :type numbered: bool
        :rtype: :class:`RemoteCall.StreamIterator`

        Follow job's streamed result, already collected and collected in the
        future, until the job terminates.

        According to protocol, if neither :obj:`since` nor :obj:`recent` were
        provided, stream behaves as ``recent=0`` was specified.

        Usage::

           rpc = HarpCaller(dispatcher_address)
           job = rpc.job("e1c7b937-2428-42c2-9f22-f8fcf2906e65")
           for msg in job.follow():
               consume(msg)
           # alternatively:
           #for (i,msg) in job.follow(numbered = True):
           #    consume(i, msg)

        See also :meth:`stream()`.
        '''
        request = {
            "harpcaller": 1,
            "follow_stream": self.job_id,
            "since":  since,  # to be deleted if empty
            "recent": recent, # to be deleted if empty
        }
        if request["since"] is None:
            del request["since"]
        if request["recent"] is None:
            del request["recent"]

        conn = self.dispatcher.connect()
        conn.send(request)
        return RemoteCall.StreamIterator(self, conn, numbered)

    def stream(self, since = None, recent = None, numbered = False):
        '''
        :param since: message number to read stream result from
        :type since: non-negative integer
        :param recent: number of messages before current to read stream result
            from
        :type recent: non-negative integer
        :param numbered: if ``True``, iterator will produce pairs ``(pktid,
            msg)``, with :obj:`pktid` having an analogous meaning to
            :obj:`since`
        :type numbered: bool
        :rtype: :class:`RemoteCall.StreamIterator`

        Retrieve job's streamed result collected up until call. Function does
        not wait for the job to terminate.

        According to protocol, if neither :obj:`since` nor :obj:`recent` were
        provided, stream behaves as ``since=0`` was specified.

        Usage::

           rpc = HarpCaller(dispatcher_address)
           job = rpc.job("ef581fb8-a0ae-49a3-9eb3-a2cc505b28c9")
           for msg in job.stream():
               consume(msg)
           # alternatively:
           #for (i,msg) in job.stream(numbered = True):
           #    consume(i, msg)

        See also :meth:`follow()`.
        '''
        request = {
            "harpcaller": 1,
            "read_stream": self.job_id,
            "since":  since,  # to be deleted if empty
            "recent": recent, # to be deleted if empty
        }
        if request["since"] is None:
            del request["since"]
        if request["recent"] is None:
            del request["recent"]

        conn = self.dispatcher.connect()
        conn.send(request)
        return RemoteCall.StreamIterator(self, conn, numbered)

    def result(self, wait = False):
        '''
        :param wait: wait for the job to terminate
        :type wait: bool
        :rtype: JSON-serializable data, :data:`CALL_NOT_FINISHED`,
            :data:`CALL_CANCELLED`, :class:`RemoteException`,
            :class:`RemoteError`, or :class:`CommunicationError`

        Get job's end result, regardless of how the job terminated. If
        ``wait=False`` was specified and the job is still running,
        :data:`CALL_NOT_FINISHED` is returned.

        Note that this function *returns* exception's instance
        (:class:`RemoteException`, :class:`RemoteError`,
        :class:`CommunicationError`) instead of throwing it.

        See also :meth:`get()`.
        '''
        if not self._has_result:
            response = self.dispatcher.request({
                "harpcaller": 1,
                "get_result": self.job_id,
                "wait": wait,
            })
            self._remember_result(response)
        return self._result

    def _remember_result(self, message):
        self._has_result = True
        if message is None:
            self._result = CommunicationError("unexpected EOF")
        if "no_result" in message and message["no_result"]:
            # get_result with wait=false
            self._result = CALL_NOT_FINISHED
        elif "continue" in message and message["continue"]:
            # read_stream
            self._result = CALL_NOT_FINISHED
        elif "cancelled" in message and message["cancelled"]:
            self._result = CALL_CANCELLED
        elif "result" in message:
            self._result = message["result"]
        elif "exception" in message:
            # {"type": "...", "message": "...", "data": ...}
            exception = message["exception"]
            self._result = RemoteException(
                exception["type"],
                exception["message"],
                exception.get("data"),
            )
        elif "error" in message:
            # {"type": "...", "message": "...", "data": ...}
            error = message["error"]
            self._result = RemoteError(
                error["type"],
                error["message"],
                error.get("data"),
            )
        #else: invalid message; return an exception

    def get(self, wait = True):
        '''
        :param wait: wait for the job to terminate
        :type wait: bool
        :rtype: JSON-serializable data or :data:`CALL_NOT_FINISHED`
        :throws: :class:`RemoteException`, :class:`RemoteError`,
            :class:`CancelledException`, or :class:`CommunicationError`

        Get job's end result, waiting for job's termination.

        See also :meth:`result()`.
        '''
        result = self.result(wait = wait)
        if isinstance(result, HarpException):
            raise result
        elif result is CALL_CANCELLED:
            raise CancelledException()
        return result

    def cancel(self):
        '''
        :return: ``True`` if the job was still running, ``False`` otherwise

        Cancel execution of the job.
        '''
        response = self.dispatcher.request({
            "harpcaller": 1,
            "cancel": self.job_id,
        })
        return response["cancelled"] # True | False

    def __repr__(self):
        return '<%s.%s "%s">' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.job_id,
        )

# }}}
#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
