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

    def __del__(self):
        self.close()

    def close(self):
        if self.sockf is not None:
            self.sockf.close()
        self.sockf = None

    def request(self, obj, close = True):
        self.send(obj)
        response = self.receive()
        if close:
            self.close()
        return response

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

class KorRPCError(Exception, object):
    pass

class CommunicationError(KorRPCError):
    pass

class RemoteException(KorRPCError):
    def __init__(self, type, message, data = None):
        super(RemoteException, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

    #def __str__(self):
    #    pass # TODO: implement me

class RemoteError(KorRPCError):
    def __init__(self, type, message, data = None):
        super(RemoteError, self).__init__(message)
        self.type = type
        self.message = message
        self.data = data

    #def __str__(self):
    #    pass # TODO: implement me

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
        conn = self.connect()
        return conn.request(req, close = True)

    def __getitem__(self, hostname):
        return RemoteServer(self, hostname)

    def __repr__(self):
        return "<%s.%s %s:%d>" % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.host,
            self.port,
        )

#-----------------------------------------------------------------------------

class RemoteServer(object):
    def __init__(self, dispatcher, hostname):
        self._dispatcher = dispatcher
        self._hostname = hostname

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

    def __call__(self, *args, **kwargs):
        # TODO: timeout, max_exec_time, queue, queue_concurrency
        if len(args) == 0 and len(kwargs) > 0:
            call_args = kwargs
        elif len(kwargs) == 0:
            call_args = args

        reply = self.dispatcher.request({
            "korrpcdid": 1,
            "host": self.server._hostname,
            "procedure": self.procedure,
            "arguments": call_args,
        })

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
    def __init__(self, dispatcher, job_id):
        self.dispatcher = dispatcher
        self.job_id = job_id

    def follow(self, since = None, recent = None):
        # TODO: all_packets = call.follow().all()
        # TODO: for p in call.follow(): ...
        pass # TODO

    def stream(self, since = None, recent = None):
        pass # TODO

    def get(self, wait = False):
        response = self.dispatcher.request({
            "korrpcdid": 1,
            "get_result": self.job_id,
            "wait": wait,
        })
        if response is None:
            raise CommunicationError("unexpected EOF")
        if "no_result" in response and response["no_result"]:
            return CALL_NOT_FINISHED
        elif "cancelled" in response and response["cancelled"]:
            return CALL_CANCELLED
        elif "result" in response:
            return response["result"]
        elif "exception" in response:
            # {"type": "...", "message": "...", "data": ...}
            exception = response["exception"]
            raise RemoteException(
                exception["type"],
                exception["message"],
                exception.get("data"),
            )
        elif "error" in response:
            # {"type": "...", "message": "...", "data": ...}
            error = response["error"]
            raise RemoteError(
                error["type"],
                error["message"],
                error.get("data"),
            )
        #else: invalid response; throw an exception

    def cancel(self):
        pass # TODO

    def __repr__(self):
        return '<%s.%s "%s">' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.job_id,
        )

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
