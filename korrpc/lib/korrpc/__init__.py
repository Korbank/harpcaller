#!/usr/bin/python

import socket
import json

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

class KorRPCCallError(Exception):
    pass

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

        conn = self.dispatcher.connect()
        conn.send({
            "korrpcdid": 1,
            "host": self.server._hostname,
            "procedure": self.procedure,
            "arguments": call_args,
        })
        reply = conn.receive()
        conn.close()

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

    def follow(self):
        pass # TODO

    def stream(self):
        pass # TODO

    def result(self):
        pass # TODO

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
