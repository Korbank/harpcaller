#!/usr/bin/python

import socket
import ssl
import json
import SocketServer

import proc

# TODO: use logging

#-----------------------------------------------------------------------------
# RequestHandler {{{

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

        try:
            (proc_name, arguments) = self.read_request()
        except RequestHandler.RequestError, e:
            self.send(e.struct())
            return

        # TODO: handle "no such procedure" error
        procedure = self.server.procedures[proc_name]

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
        if isinstance(procedure, proc.StreamedResult):
            self.send({"korrpc": 1, "stream_result": True})
            for packet in procedure(*args, **kwargs):
                self.send({"stream": packet})
            self.send({"result": procedure.result()})
        else:
            self.send({"korrpc": 1, "stream_result": False})
            self.send({"result": procedure(*args, **kwargs)})

    def finish(self):
        pass

    def read_request(self):
        # TODO: catch read errors
        read_buffer = []
        fragment = self.request.read(self.server.max_line)
        while "\n" not in fragment and fragment != "":
            read_buffer.append(fragment)
            fragment = self.request.read(self.server.max_line)
        read_buffer.append(fragment)
        read_buffer = "".join(read_buffer)
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

# }}}
#-----------------------------------------------------------------------------
# SSLServer {{{

class SSLServer(SocketServer.ForkingMixIn, SocketServer.BaseServer, object):
    def __init__(self, host, port, procs, key_file, cert_file, ca_file = None):
        if host is None:
            host = ""
        # XXX: hardcoded request handler class, since I won't use this server
        # with anything else
        super(SSLServer, self).__init__((host, port), RequestHandler)
        # these two are parameters for RequestHandler, but can't be set in
        # RequestHandler.__init__() (it doesn't get called O_o)
        self.max_line = 4096
        self.procedures = procs

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
        (client_socket, (addr, port)) = self.socket.accept()
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
        client_socket.unwrap()
        self.close_request(client_socket)

    def close_request(self, client_socket):
        # NOTE: closing happens both in parent and child processes; it should
        # merely close the file descriptor
        client_socket.close()

# }}}
#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
