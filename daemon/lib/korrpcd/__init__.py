#!/usr/bin/python

import socket
import ssl
import SocketServer

import os # temporary, for os.getpid()

#-----------------------------------------------------------------------------

# TODO: use logging

#-----------------------------------------------------------------------------

# TODO: do something useful here, like calling loaded functions
class RequestHandler(SocketServer.BaseRequestHandler):
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
            line = self.request.read()
        except Exception, e:
            print "[$$=%d] exception: %s" % (os.getpid(), e)
            raise
        print "[$$=%d] got line: '%s'" % (os.getpid(), line.strip())
        self.request.write("[$$=%d] bye\n" % (os.getpid()))

    def finish(self):
        pass

#-----------------------------------------------------------------------------

class SSLServer(SocketServer.ForkingMixIn, SocketServer.BaseServer, object):
    def __init__(self, host, port, key_file, cert_file, ca_file = None):
        if host is None:
            host = ""
        # XXX: hardcoded request handler class, since I won't use this server
        # with anything else
        super(SSLServer, self).__init__((host, port), RequestHandler)
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
