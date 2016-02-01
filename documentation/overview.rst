**************************
High-level system overview
**************************

.. toctree::
   :maxdepth: 2

KorRPC is a system that allows calling procedures on remote machines and
collects their results of various types.

Main intended consumer of KorRPC is a web application, so KorRPC needs to work
in asynchronous manner: call request returns job identifier, so the job's
status and returned value can be obtained at later time.

From the called machine's perspective, KorRPC system is synchronous, keeping
a single connection (one per request) through which a request is sent one way
and all the results are sent in the opposite direction.

Called procedure always returns a single (possibly complex) value at the end
or terminates with an exception, but the procedure may additionally produce
multiple values at any points between start and termination. These values are
recorded as a part of the procedure's result and are available immediately and
at later time.

KorRPC system is designed to allow some level of load control, thanks to being
a task queue. Call requests can specify what queue are they to be put in and
how many calls from the queue can be running simultaneously (concurrency
level). Queues are created as needed and are destroyed as soon as they become
empty, so there's no need to pre-configure them for KorRPC.
