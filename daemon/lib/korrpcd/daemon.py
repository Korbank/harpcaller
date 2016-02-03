#!/usr/bin/python
'''
Network server and daemonization operations
-------------------------------------------

.. autoclass:: SSLServer
   :members:

.. autoclass:: RequestHandler
   :members:

'''
#-----------------------------------------------------------------------------

import socket
import ssl
import json
import SocketServer

import proc

# TODO: use logging

#-----------------------------------------------------------------------------
# RequestHandler {{{

class RequestHandler(SocketServer.BaseRequestHandler, object):
    '''
    KorRPC call request handler.

    Attributes defined by parent class:

    .. attribute:: request

       client socket, as returned by :meth:`SSLServer.get_request()` in the
       first field

    .. attribute:: client_address

       client address ``(IP, port)``, as returned by
       :meth:`SSLServer.get_request()` in the second field

    .. attribute:: server

       :class:`SSLServer` instance
    '''

    #-------------------------------------------------------
    # RequestError {{{

    class RequestError(Exception):
        '''
        Request processing error. Note that this is a different thing than
        exception raised in called procedure's code.
        '''
        def __init__(self, type, message, data = None):
            super(RequestHandler.RequestError, self).__init__(message)
            self._type = type
            self._message = message
            self._data = data

        def struct(self):
            '''
            Return the error as a dict suitable for transmitting to client.
            '''
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

    # }}}
    #-------------------------------------------------------

    def setup(self):
        '''
        Prepare request handler instance for work.
        '''
        pass

    def handle(self):
        '''
        Handle the connection. This means reading client's request, processing
        it, and sending results back.
        '''

        try:
            (proc_name, arguments) = self.read_request()
        except RequestHandler.RequestError, e:
            self.send(e.struct())
            return

        if proc_name not in self.server.procedures:
            e = RequestHandler.RequestError(
                "no_such_procedure",
                "no such procedure",
                {"procedure": proc_name},
            )
            self.send(e.struct())
            return

        procedure = self.server.procedures[proc_name]

        if isinstance(arguments, (list, tuple)):
            args = arguments
            kwargs = {}
        elif isinstance(arguments, dict):
            args = ()
            kwargs = arguments
        else:
            e = RequestHandler.RequestError(
                "invalid_argument_list",
                "argument list is neither a list nor a hash",
            )
            self.send(e.struct())
            return

        try:
            if isinstance(procedure, proc.StreamingProcedure):
                self.send({"korrpc": 1, "stream_result": True})
                for packet in procedure(*args, **kwargs):
                    self.send({"stream": packet})
                self.send({"result": procedure.result()})
            else: # isinstance(procedure, proc.Procedure)
                self.send({"korrpc": 1, "stream_result": False})
                self.send({"result": procedure(*args, **kwargs)})
        except RequestHandler.RequestError, e:
            # possible exceptions of this type:
            #   - packet serialization error
            #   - result serialization error
            #   - send() error
            try:
                self.send(e.struct())
            except:
                pass # ignore error sending errors
        except Exception, e:
            exception_message = {
                "exception": {
                    "type": e.__class__.__name__,
                    "message": str(e),
                    "data": {
                        "class": e.__class__.__name__,
                        "module": e.__class__.__module__,
                    }
                }
            }
            try:
                self.send(exception_message)
            except:
                pass # ignore error sending errors

    def finish(self):
        '''
        Clean up request handler after work.
        '''
        pass

    def read_request(self):
        '''
        :return: procedure name and its arguments
        :rtype: tuple (unicode, dict | list)
        :raise: :exc:`RequestHandler.RequestError`

        Read call request from socket.
        '''
        # TODO: catch read errors
        read_buffer = []
        fragment = self.request.read(self.server.max_line)
        while "\n" not in fragment and fragment != "":
            read_buffer.append(fragment)
            fragment = self.request.read(self.server.max_line)
        read_buffer.append(fragment)
        read_buffer = "".join(read_buffer)
        if read_buffer == "": # EOF
            raise RequestHandler.RequestError(
                "invalid_request",
                "request incomplete or too long",
            )

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
        '''
        :param data: response to send
        :type data: dict

        Send response (stream, returned value, exception, error) to client.
        '''
        try:
            line = json.dumps(data, sort_keys = True)
        except Exception, e:
            raise RequestHandler.RequestError("invalid_message", str(e))

        try:
            self.request.write(line + "\n")
        except socket.error, e:
            # nobody to report send errors to, but it will abort a possible
            # iteration
            raise RequestHandler.RequestError("network_error", str(e))

# }}}
#-----------------------------------------------------------------------------
# SSLServer {{{

class SSLServer(SocketServer.ForkingMixIn, SocketServer.BaseServer, object):
    '''
    :param host: address to bind to
    :type host: string or ``None``
    :param port: port to listen on
    :type port: integer
    :param procs: table with procedures to expose
    :type procs: dict(name->callable)
    :param cert_file: X.509 certificate
    :type cert_file: path
    :param key_file: private key for :obj:`cert_file`
    :type key_file: path
    :param ca_file: file with all X.509 CA certificates
    :type ca_file: path

    SSL connection server. Uses :class:`RequestHandler` to handle SSL
    connections.
    '''
    def __init__(self, host, port, procs, cert_file, key_file, ca_file = None):
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
        '''
        :return: file descriptor

        Return file descriptor to wait for I/O events (``poll()``).
        '''
        return self.socket.fileno()

    def get_request(self):
        '''
        :return: client socket and client address (IP+port)
        :rtype: 2-tuple (socket, address)

        Accept a new connection.
        '''
        # XXX: SSL protocol errors are handled by SocketServer.BaseServer
        (client_socket, (addr, port)) = self.socket.accept()
        return (client_socket, (addr, port))

    # TODO: handle error (when RequestHandler.handle() raises an exception)
    #def handle_error(self, client_socket, client_address):
    #    #(address, port) = client_address
    #    pass

    def server_activate(self):
        '''
        Prepare server for accepting connections.
        '''
        self.socket.listen(1) # socket backlog of 1

    def server_bind(self):
        '''
        Bind server to its socket.
        '''
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()

    def server_close(self):
        '''
        Shutdown the server.
        '''
        self.socket.close()

    def shutdown_request(self, client_socket):
        '''
        :param client_socket: socket where client connection is to be
            terminated

        Properly close the client socket, with notifying the client.

        In forking SocketServer, this happens in child (worker) process.
        '''
        # NOTE: shutdown only happens in child process (the one the socket
        # belongs to); it should involve informing the other end properly that
        # the connection is being closed
        try:
            client_socket.unwrap()
        except socket.error, e:
            pass # possibly a prematurely closed socket
        self.close_request(client_socket) # this, or duplicate its job here

    def close_request(self, client_socket):
        '''
        :param client_socket: socket to close

        Close the client socket, but without tearing down the connection (e.g.
        SSL shutdown handshake).

        In forking SocketServer, this is called in parent (listener) process,
        and may be called by implementation of :meth:`shutdown_request()`.
        '''
        # NOTE: closing happens both in parent and child processes; it should
        # merely close the file descriptor
        client_socket.close()

# }}}
#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
