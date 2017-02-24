**************************
High-level system overview
**************************

.. toctree::
   :maxdepth: 2

HarpCaller is a system that allows calling procedures on remote machines and
collects their results of various types. Procedures to be called are part of
system's configuration, so they can do many administrative tasks. This is much
more robust than a set of shell scripts called through SSH, especially when
the procedures need to be parametrized and/or return some structured data.

Main intended consumer of HarpCaller is a web application, so HarpCaller needs
to work in asynchronous manner: call request returns job identifier, so the
job's status and returned value can be obtained at later time.

From the called machine's perspective, HarpCaller system is synchronous,
keeping a single connection (one per request) through which a request is sent
one way and all the results are sent in the opposite direction.

Called procedure always returns a single (possibly complex) value at the end
or terminates with an exception, but the procedure may additionally produce
multiple values at any points between start and termination. These values are
recorded as a part of the procedure's result and are available immediately and
at later time.

HarpCaller system is designed to allow some level of load control, thanks to
being a task queue. Call requests can specify what queue are they to be put in
and how many calls from the queue can be running simultaneously (concurrency
level). Queues are created as needed and are destroyed as soon as they become
empty, so there's no need to pre-configure them for HarpCaller. Queues are
arbitrary and have nothing particular in common with called host, procedure,
or procedure's arguments, so it is possible to issue the same call request
twice or more, each time to a different queue.


Components of the system
========================

HarpCaller system is divided into three parts: daemon, dispatcher, and client
library.

Daemon
------

:manpage:`harpd(8)` daemon is a service running on every server that can be
a target for RPC call. It is meant to carry out any procedure that is called
and send the value that the procedure returned as a response to RPC call. Code
for the procedures available to daemon is supplied as daemon's configuration.

Dispatcher
----------

HarpCaller (request dispatcher) is a single central service tasked with
connecting to daemons to pass them call requests and receive call results, and
to store these results on disk for later access.

Given the queues are independent from any part of call requests, dispatcher is
the place where queueing occurs.

Dispatcher is also the service that client library talks to directly in
typical use.

Client library
--------------

Python :mod:`harp` module is a client implementation of the protocol to talk
to HarpCaller and to :manpage:`harpd(8)` services (*note*: :manpage:`harpd(8)`
uses slightly different protocol). The primary use case for this interface was
to allow issuing commands to servers from within a web application, but it
should be equally convenient for other uses.

Module documentation: :ref:`client-lib-api`

Example usage: :ref:`client-lib-examples`

