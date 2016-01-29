#!/usr/bin/python

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
CALL_CANCELLED = CallCancelled()

#-----------------------------------------------------------------------------
# JSON connection reader {{{

class JSONConnection(object):
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.sockf = None
        self.connect()

    def connect(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        s.connect((self.host, self.port))
        self.sockf = s.makefile()
        s.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def __del__(self):
        self.close()

    def close(self):
        if self.sockf is not None:
            self.sockf.close()
        self.sockf = None

    def send(self, obj):
        # buffered write, so I can skip string concatenation to get whole line
        # written at once
        self.sockf.write(json.dumps(obj))
        self.sockf.write("\n")
        self.sockf.flush()

    def receive(self):
        line = self.sockf.readline()
        if line == "":
            return None
        return json.loads(line)

# }}}
#-----------------------------------------------------------------------------
# exceptions {{{

class KorRPCException(Exception, object):
    pass

class CommunicationError(KorRPCException):
    pass

class CancelledException(KorRPCException):
    pass

class RemoteException(KorRPCException):
    def __init__(self, type, message, data = None):
        super(RemoteException, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

class RemoteError(KorRPCException):
    def __init__(self, type, message, data = None):
        super(RemoteError, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

# }}}
#-----------------------------------------------------------------------------

class KorRPC(object):
    def __init__(self, host, port = 3502):
        self.host = host
        self.port = port

    def job(self, job_id):
        return RemoteCall(self, job_id)

    def connect(self):
        return JSONConnection(self.host, self.port)

    def request(self, req):
        with self.connect() as conn:
            conn.send(req)
            return conn.receive()

    def __call__(self, host, queue = None, concurrency = None,
                 timeout = None, max_exec_time = None):
        return RemoteServer(self, host, queue, concurrency,
                            timeout, max_exec_time)

    def __repr__(self):
        return "<%s.%s %s:%d>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.host,
            self.port,
        )

#-----------------------------------------------------------------------------

class RemoteServer(object):
    def __init__(self, dispatcher, hostname, queue, concurrency,
                 timeout, max_exec_time):
        self._dispatcher = dispatcher
        self._hostname = hostname
        self._queue = queue
        self._concurrency = concurrency
        self._timeout = timeout
        self._max_exec_time = max_exec_time

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
        return RemoteProcedure(self._dispatcher, self, procedure)

    def __str__(self):
        return self._hostname

    def __repr__(self):
        return "<%s.%s %s>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self._hostname,
        )

#-----------------------------------------------------------------------------

class RemoteProcedure(object):
    def __init__(self, dispatcher, server, procedure):
        self.dispatcher = dispatcher
        self.server = server
        self.procedure = procedure

    def host(self):
        return str(self.server)

    def __call__(self, *args, **kwargs):
        if len(args) == 0 and len(kwargs) > 0:
            call_args = kwargs
        elif len(kwargs) == 0:
            call_args = args

        request = {
            "korrpcdid": 1,
            "host": str(self.server),
            "procedure": self.procedure,
            "arguments": call_args,
        }
        request.update(self.server._call_options())
        reply = self.dispatcher.request(request)

        return RemoteCall(self.dispatcher, reply["job_id"])

    def __repr__(self):
        return "<%s.%s %s:%s()>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.server._hostname,
            self.procedure,
        )

#-----------------------------------------------------------------------------

class RemoteCall(object):

    #-------------------------------------------------------
    # StreamIterator {{{

    class StreamIterator(object):
        def __init__(self, remote_call, conn):
            self.remote_call = remote_call
            self.conn = conn

        def __iter__(self):
            return self

        def next(self):
            packet = self.conn.receive()
            if packet is None or "packet" not in packet:
                # TODO: if packet != None, save the result in a field of
                # self.remote_call object
                self.conn.close()
                raise StopIteration()
            return packet["data"]

        def all(self):
            return [packet for packet in self]

    # }}}
    #-------------------------------------------------------

    def __init__(self, dispatcher, job_id):
        self.dispatcher = dispatcher
        self.job_id = job_id

    def id(self):
        return self.job_id

    def follow(self, since = None, recent = None):
        # TODO: return packet numbers somehow, so `since' is easy to work with
        request = {
            "korrpcdid": 1,
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
        return RemoteCall.StreamIterator(self, conn)

    def stream(self, since = None, recent = None):
        # TODO: return packet numbers somehow, so `since' is easy to work with
        request = {
            "korrpcdid": 1,
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
        return RemoteCall.StreamIterator(self, conn)

    def result(self, wait = False):
        response = self.dispatcher.request({
            "korrpcdid": 1,
            "get_result": self.job_id,
            "wait": wait,
        })
        if response is None:
            return CommunicationError("unexpected EOF")
        if "no_result" in response and response["no_result"]:
            return CALL_NOT_FINISHED
        elif "cancelled" in response and response["cancelled"]:
            return CALL_CANCELLED
        elif "result" in response:
            return response["result"]
        elif "exception" in response:
            # {"type": "...", "message": "...", "data": ...}
            exception = response["exception"]
            return RemoteException(
                exception["type"],
                exception["message"],
                exception.get("data"),
            )
        elif "error" in response:
            # {"type": "...", "message": "...", "data": ...}
            error = response["error"]
            return RemoteError(
                error["type"],
                error["message"],
                error.get("data"),
            )
        #else: invalid response; return an exception

    def get(self, wait = True):
        result = self.result(wait = wait)
        if isinstance(result, KorRPCException):
            raise result
        elif result is CALL_CANCELLED:
            raise CancelledException()
        return result

    def cancel(self):
        response = self.dispatcher.request({
            "korrpcdid": 1,
            "cancel": self.job_id,
        })
        return response["cancelled"] # True | False

    def __repr__(self):
        return '<%s.%s "%s">' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.job_id,
        )

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
