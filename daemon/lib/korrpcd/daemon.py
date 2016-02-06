#!/usr/bin/python
'''
Network server and daemonization operations
-------------------------------------------

.. autoclass:: SSLServer
   :members:

.. autoclass:: RequestHandler
   :members:

.. autoclass:: Daemon
   :members:

'''
#-----------------------------------------------------------------------------

import socket
import ssl
import json
import SocketServer
import logging
import os
import sys
import atexit

from log import message as log
import proc

#-----------------------------------------------------------------------------
# Daemon {{{

class Daemon(object):
    '''
    Daemonization helper. If detach was requested, :func:`os.fork()` is
    called, the parent process waits for start confirmation
    (:meth:`confirm()`) and exits with code of ``0`` (``1`` if no confirmation
    was received).

    Child process changes its working directory to :file:`/` and after
    confirmation, closes its STDIN, STDOUT, and STDERR (this way any uncaught
    exception is printed to terminal).
    '''

    CONFIRMATION = "OK\n"

    #-------------------------------------------------------
    # PidFile(filename) {{{

    class PidFile(object):
        '''
        Handle of a pidfile.

        Creating an instance of this class automatically registers
        :meth:`close()` as :mod:`atexit` handler. See :meth:`release()` if you
        want to detach your daemon from terminal.
        '''
        def __init__(self, filename):
            '''
            :param filename: pidfile path
            '''
            self.filename = os.path.abspath(filename)
            self.fh = None
            fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0666)
            self.fh = os.fdopen(fd, 'w')
            self.update()
            atexit.register(self.close)

        def release(self):
            '''
            Close pidfile without deleting it.

            To be used in parent process when detaching from terminal.
            '''
            if self.fh is not None:
                self.fh.close()
                self.fh = None

        def close(self):
            '''
            Close and delete pidfile, if a pidfile is open.
            '''
            if self.fh is not None:
                self.fh.close()
                self.fh = None
                os.unlink(self.filename)

        def update(self):
            '''
            Update PID stored in pidfile to the one of this process.
            '''
            self.fh.seek(0)
            self.fh.write("%d\n" % (os.getpid(),))
            self.fh.flush()
            self.fh.truncate()

    # }}}
    #-------------------------------------------------------

    def __init__(self, pidfile = None, detach = False):
        '''
        :param pidfile: pidfile path
        :param detach: whether the daemon should detach from terminal or not
        '''
        self.pidfile = None
        self.should_detach = detach
        self.detach_fh = None
        if pidfile is not None:
            self.pidfile = Daemon.PidFile(pidfile)
        if self.should_detach:
            self._detach()

    def confirm(self):
        '''
        Confirm to parent that initialization was successful and daemon can
        continue work from here.

        Method to be called in child process when detaching from terminal.
        '''
        if self.should_detach:
            self._close_stdio()
        if self.detach_fh:
            self.detach_fh.write(self.CONFIRMATION)
            self.detach_fh.close()
            self.detach_fh = None

    def _detach(self):
        '''
        Call :func:`os.fork()`, keeping a one-way channel for initialization
        confirmation, and call role handler method (:meth:`_child_process()`
        or :meth:`_parent_process()`).

        Method does not return in parent process.
        '''
        (read_fh, write_fh) = self._pipe()
        child_pid = os.fork()
        if child_pid == 0:
            self._double_fork()
            read_fh.close()
            self.detach_fh = write_fh
            self._child_process()
        else:
            write_fh.close()
            self._parent_process(read_fh)

    def _double_fork(self):
        '''
        Lose controlling terminal permanently, by so-called "double fork"
        procedure.

        First, :func:`os.setsid()` is called in the child process (just after
        :func:`os.fork()`), so the process loses its current controlling
        terminal. Then :func:`os.fork()` is called for the second time, and
        this time parent process simply exits. Child is not a session leader
        anymore, so it can't gain controlling terminal accidentally, e.g. by
        opening log output.
        '''
        os.setsid()
        if os.fork() > 0:
            os._exit(0)

    def _child_process(self):
        '''
        Child role handler.

        Method updates PID stored in pidfile (if any) and changes working
        directory to :file:`/`.

        Function does not close STDIO. This is left for just after
        initialization confirmation (:meth:`confirm()`), so any uncaught
        exceptions can be printed to the screen.
        '''
        if self.pidfile is not None:
            self.pidfile.update()
        os.chdir("/")

    def _parent_process(self, detach_fh):
        '''
        Parent role handler.

        Parent process waits for the child to confirm that initialization was
        successful and exits with ``0``. If child fails to confirm the
        success, parent exits with ``1``.
        '''
        if self.pidfile is not None:
            self.pidfile.release() # it's no longer our pidfile
        confirmation = detach_fh.readline()
        detach_fh.close()
        if confirmation == self.CONFIRMATION:
            os._exit(0)
        elif confirmation == "": # premature EOF
            os._exit(1)
        else: # WTF?
            os._exit(2)

    def _pipe(self):
        '''
        :return: (read_handle, write_handle)

        Create a pair of connected filehandles.
        '''
        (read_fd, write_fd) = os.pipe()
        read_fh = os.fdopen(read_fd, 'r')
        write_fh = os.fdopen(write_fd, 'w')
        return (read_fh, write_fh)

    def _close_stdio(self):
        '''
        Close STDIN, STDOUT, and STDERR. For safety, :file:`/dev/null` is
        opened instead.
        '''
        devnull = os.open("/dev/null", os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        os.close(devnull)

# }}}
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

        # XXX: SystemExit exception is not caught everywhere here, so there
        # can be a situation when it propagates without control, but I don't
        # like huge try..except around the whole method, so I'll leave it

        logger = logging.getLogger("korrpcd.daemon.handle_client")

        try:
            (proc_name, arguments, (user, password)) = self.read_request()
        except SystemExit:
            logger.info(log("aborted due to shutdown",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1]))
            e = RequestHandler.RequestError(
                "shutdown",
                "service is shutting down",
            )
            self.send(e.struct())
            return
        except RequestHandler.RequestError, e:
            logger.info(log("error when reading request",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1],
                            error = e.struct()["error"]))
            self.send(e.struct())
            return

        if not self.server.authdb.authenticate(user, password):
            logger.info(log("authentication error",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1],
                            user = user))
            e = RequestHandler.RequestError(
                "auth_error",
                "unknown user or wrong password",
            )
            self.send(e.struct())
            return

        if proc_name not in self.server.procedures:
            logger.info(log("no such procedure",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1],
                            procedure = proc_name))
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
            logger.info(log("invalid argument list in request",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1],
                            # XXX: `arguments' comes from deserialized JSON,
                            # so it can be serialized back to JSON safely
                            argument = arguments))
            e = RequestHandler.RequestError(
                "invalid_argument_list",
                "argument list is neither a list nor a hash",
            )
            self.send(e.struct())
            return

        try:
            logger.info(log(
                "calling procedure",
                client_address = self.client_address[0],
                client_port = self.client_address[1],
                procedure = proc_name,
                streaming = isinstance(procedure, proc.StreamingProcedure),
            ))
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
            logger.info(log(
                "procedure call error",
                client_address = self.client_address[0],
                client_port = self.client_address[1],
                procedure = proc_name,
                error = e.struct()["error"],
            ))
            try:
                self.send(e.struct())
            except:
                pass # ignore error sending errors
        except SystemExit:
            logger.info(log("aborted due to shutdown",
                            client_address = self.client_address[0],
                            client_port = self.client_address[1],
                            procedure = proc_name))
            e = RequestHandler.RequestError(
                "shutdown",
                "service is shutting down",
            )
            self.send(e.struct())
            return
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
        :return: procedure name, its arguments, and authentication data
        :rtype: tuple (unicode, dict | list, (unicode, unicode))
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
        #   * request["auth"]["user"] ~~ str | unicode
        #   * request["auth"]["password"] ~~ str | unicode

        try:
            return (
                request["procedure"],
                request["arguments"],
                (request["auth"]["user"], request["auth"]["password"])
            )
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
    def __init__(self, host, port, procs, authdb,
                 cert_file, key_file, ca_file = None):
        logger = logging.getLogger("korrpcd.daemon.server")
        if host is None:
            host = ""
        # XXX: hardcoded request handler class, since I won't use this server
        # with anything else
        super(SSLServer, self).__init__((host, port), RequestHandler)
        # these are parameters for RequestHandler, but can't be set in
        # RequestHandler.__init__() (it doesn't get called O_o)
        self.max_line = 4096
        self.procedures = procs
        self.authdb = authdb

        # necessary to detect if this is the child or parent process, so child
        # won't forward signal to its older siblings
        self.parent_pid = os.getpid()

        logger.info(log("listening on SSL socket", host = host, port = port))
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

    def handle_signal(self, signum, stack_frame):
        '''
        Signal handler for :func:`signal.signal()` function. Calls
        ``sys.exit(0)``, in daemon's main process additionally forwarding
        signal to all the children.
        '''
        in_parent = (self.parent_pid == os.getpid())
        if in_parent:
            logger = logging.getLogger("korrpcd.daemon.server")
        else:
            logger = logging.getLogger("korrpcd.daemon.handle_client")
        if in_parent:
            logger.info(log("received signal, forwarding to children and exiting",
                            signal = signum))
            if self.active_children is not None:
                for pid in self.active_children:
                    os.kill(pid, signum)
        else:
            logger.info(log("received signal, exiting", signal = signum))
        sys.exit(0)

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
        logger = logging.getLogger("korrpcd.daemon.server")
        logger.info(log(
            "new client connected",
            client_address = addr, client_port = port
        ))
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
        logger = logging.getLogger("korrpcd.daemon.server")
        logger.info(log("shutting down the listening socket"))
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
