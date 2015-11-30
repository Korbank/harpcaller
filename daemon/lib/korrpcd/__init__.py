#!/usr/bin/python

import socket
import ssl
import json
import SocketServer

import os # temporary, for os.getpid()

#-----------------------------------------------------------------------------

# TODO: use logging

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
# stub for user-supplied procedures {{{

import time

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
            "delayed": False,
        }
    else:
        return {
            "call_type": "args",
            "args_count": len(args),
            "delayed": False,
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

_PROCEDURES = {
    "return_immediate": return_immediate,
    "return_delayed":   return_delayed,
    "stream_immediate": stream_immediate,
    "stream_delayed":   stream_delayed,
    "stream_infinity":  stream_infinity,
}

# }}}
#-----------------------------------------------------------------------------

# TODO: do something useful here, like calling loaded functions
class RequestHandler(SocketServer.BaseRequestHandler, object):
    class RequestError(Exception):
        def __init__(self, type, message, data = None):
            super(RequestHandler.RequestError, self).__init__(message)
            self._type = type
            self._message = message
            self._data = data

        def struct(self):
            if self._data is not None:
                error = {
                    "type": self._type,
                    "message": self._message,
                    "data": self._data,
                }
            else:
                error = {
                    "type": self._type,
                    "message": self._message,
                }

            return { "korrpc": 1, "error": error }

    def setup(self):
        pass

    def handle(self):
        # self.request (client socket)
        # self.client_address (`(address, port)', as returned by
        #   SSLServer.get_request())
        # self.server (SSLServer instance)
        print "[$$=%d] request handler!" % (os.getpid())
        self.request.write("[$$=%d] hello\n" % (os.getpid()))

        try:
            (proc_name, arguments) = self.read_request()
            print "[$$=%d] got call %s%s" % (os.getpid(), proc_name, arguments)
        except RequestHandler.RequestError, e:
            self.send(e.struct())

        # TODO: better procedure lookup
        proc = _PROCEDURES[proc_name]

        if isinstance(arguments, (list, tuple)):
            args = arguments
            kwargs = {}
        elif isinstance(arguments, dict):
            args = ()
            kwargs = arguments
        else:
            return # TODO: signal an error

        # TODO: try-catch exceptions from call
        # TODO: try-catch exceptions from serializing results
        # TODO: intercept "broken pipe" situation and terminate early
        if isinstance(proc, StreamedResult):
            self.send({"korrpc": 1, "stream_result": True})
            for packet in proc(*args, **kwargs):
                self.send({"stream": packet})
            self.send({"result": proc.result()})
        else:
            self.send({"korrpc": 1, "stream_result": False})
            self.send({"result": proc(*args, **kwargs)})

        self.request.write("[$$=%d] bye\n" % (os.getpid()))

    def finish(self):
        pass

    def read_request(self):
        # TODO: catch read errors
        read_buffer = self.request.read(self.server.max_line)
        if read_buffer == "": # EOF
            return None

        lines = read_buffer.split('\n')
        if len(lines) < 2:
            raise RequestHandler.RequestError(
                "invalid_request",
                "request incomplete or too long",
            )

        if lines[1] != "":
            raise RequestHandler.RequestError(
                "invalid_request",
                "excessive data after request",
            )

        try:
            request = json.loads(lines[0])
        except Exception, e:
            raise RequestHandler.RequestError("parse_error", str(e))

        # TODO: various checks:
        #   * request["korrpc"] == 1
        #   * request["procedure"] ~~ str | unicode
        #   * request["arguments"] ~~ dict | list

        try:
            return (request["procedure"], request["arguments"])
        except Exception, e:
            raise RequestHandler.RequestError("invalid_request", str(e))

    def send(self, data):
        # TODO: intercept "broken pipe"
        self.request.write(json.dumps(data, sort_keys = True) + "\n")

#-----------------------------------------------------------------------------

class SSLServer(SocketServer.ForkingMixIn, SocketServer.BaseServer, object):
    def __init__(self, host, port, key_file, cert_file, ca_file = None):
        if host is None:
            host = ""
        # XXX: hardcoded request handler class, since I won't use this server
        # with anything else
        super(SSLServer, self).__init__((host, port), RequestHandler)
        # this one is a parameter for RequestHandler, but can't be set in
        # RequestHandler.__init__() (it doesn't get called O_o)
        self.max_line = 4096
        self.timeout = None
        self.socket = ssl.SSLSocket(
            socket.socket(socket.AF_INET, socket.SOCK_STREAM),
            server_side = True,
            ssl_version = ssl.PROTOCOL_TLSv1,
            keyfile  = key_file,
            certfile = cert_file,
            ca_certs = ca_file,
            cert_reqs = ssl.CERT_NONE,
        )
        self.server_bind()
        self.server_activate()

    def fileno(self):
        return self.socket.fileno()

    def get_request(self):
        # XXX: SSL protocol errors are handled by SocketServer.BaseServer
        print "<$$=%d> trying to get request" % (os.getpid())
        (client_socket, (addr, port)) = self.socket.accept()
        print "<$$=%d> got it" % (os.getpid())
        return (client_socket, (addr, port))

    # TODO: handle error (when RequestHandler.handle() raises an exception)
    #def handle_error(self, client_socket, client_address):
    #    #(address, port) = client_address
    #    pass

    def server_activate(self):
        self.socket.listen(1) # socket backlog of 1

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()

    def server_close(self):
        self.socket.close()

    def shutdown_request(self, client_socket):
        # NOTE: shutdown only happens in child process (the one the socket
        # belongs to); it should involve informing the other end properly that
        # the connection is being closed
        print "<$$=%d> got request to shutdown client" % (os.getpid())
        client_socket.unwrap()
        self.close_request(client_socket)

    def close_request(self, client_socket):
        # NOTE: closing happens both in parent and child processes; it should
        # merely close the file descriptor
        print "<$$=%d> got request to close client" % (os.getpid())
        client_socket.close()

#-----------------------------------------------------------------------------
# vim:ft=python
