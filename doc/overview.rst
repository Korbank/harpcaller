**************************
High-level system overview
**************************

.. toctree::
   :maxdepth: 2

Description
===========

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

Beside the usual RPC mechanisms, HarpCaller supports returning a stream of
partial results, which can be read in real time or replayed later, what comes
handy for debugging procedures that track the changes in system status.


Components of the system
========================

HarpCaller system is divided into three parts: daemon, dispatcher, and client
library.

Daemon
------

:manpage:`harpd(8)` daemon is a service running on every server that can be
a target for RPC call. It is meant to carry out any procedure that is called
and send the value that the procedure returned as a response to RPC call. The
procedures available to daemon are supplied as daemon's configuration.

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

.. only:: man

   API documentation and usage examples: :manpage:`harp(3)`

.. only:: html

   Module documentation: :ref:`client-lib-api`

   Example usage: :ref:`client-lib-examples`


Using HarpCaller
================

HarpCaller works asynchronously, what means that client receives an
acknowledgement with job ID immediately after sending a call request. This job
ID can be later used to check the job's status, read its result (or follow
streamed partial results), or wait for the job to finish. All can be done in
the same or different process, or even in multiple processes simultaneously.

HarpCaller maintains a list of known hosts that can be used as call targets.
This list, called *hosts registry*, contains target address and port (address
is either a domain name or an IP) and credentials for each of the hosts. The
hosts are identified by their names, which can be arbitrary strings. For
calling code host names are the only available way to tell where to run
a procedure.

.. code-block:: python

   import harp
   rpc = harp.HarpCaller("localhost")

   job = rpc.host("web01.example.net").run_foo()
   print job.id() # output: 8ec71d6b-28d1-4ce2-aa23-f3ea7887beda
   # job ID, being a string, can be stored in a database for later use

   # recall a job ID and check job's status
   job = rpc.job("8ec71d6b-28d1-4ce2-aa23-f3ea7887beda")
   print "job {host}:{procedure}(...)".format(
       host = job.host(),
       procedure = job.procedure(),
   )

   if job.result() is harp.CALL_NOT_FINISHED:
       print "job still running"
   else:
       print "job terminated"

   print job.start_time() # unix timestamp
   print job.end_time()   # unix timestamp or `None' if still running

   print job.result(wait = True) # NOTE: errors are returned, not raised

End result
----------

There are two methods for retrieving job's return value:

* :meth:`job.get() <harp.RemoteCall.get()>`, which waits for the job to
  terminate (this behaviour can be changed with ``wait=False`` parameter) and
  *raises* an exception on error
* :meth:`job.result() <harp.RemoteCall.result()>`, which doesn't wait for the
  job to terminate (this behaviour can be changed with ``wait=True``
  parameter) and *returns* an exception object on error

The recommended way to check if the job is still running is to compare value
returned by :meth:`job.result() <harp.RemoteCall.result()>` with
:obj:`harp.CALL_NOT_FINISHED` constant.

Stream result
-------------

Remote procedure can return a stream of partial results, end result, or both.
Returning a stream is a feature useful for writing debugging procedures, which
could run for longer time and report state changes immediately as they happen.

Stream of partial results is recorded beside the end result and job metadata,
so it can be retrieved at a later time.

.. code-block:: python

   import harp
   rpc = harp.HarpCaller("localhost")
   job = rpc.job("8ec71d6b-28d1-4ce2-aa23-f3ea7887beda")

   # print partial results collected up until now
   for msg in job.stream(since = 0):
       print msg

   # print partial results collected from now on until the job terminates
   # NOTE: we may have missed some results that came between job.since()
   # and job.follow() calls
   for msg in job.follow(recent = 0):
       print msg

The difference between :meth:`job.follow() <harp.RemoteCall.follow()>` and
:meth:`job.stream() <harp.RemoteCall.stream()>` is similar to the difference
between :meth:`job.get() <harp.RemoteCall.get()>` and :meth:`job.result()
<harp.RemoteCall.result()>`: the former runs until the job terminates, while
the latter doesn't.

* :meth:`job.follow() <harp.RemoteCall.follow()>` returns an iterator
  (:class:`harp.RemoteCall.StreamIterator`) that yields messages until the job
  terminates; by default only the new messages are returned
* :meth:`job.stream() <harp.RemoteCall.stream()>` returns an iterator
  (:class:`harp.RemoteCall.StreamIterator`) that yields messages collected
  until now, without waiting for new ones; by default all messages since the
  job started are returned

Note that reading the partial results doesn't raise any exceptions. To check
for errors :meth:`job.get() <harp.RemoteCall.get()>` or :meth:`job.result()
<harp.RemoteCall.result()>` needs to be called.

Time limits
-----------

A procedure can be called with time limits specified.

.. code-block:: python

   import harp
   rpc = harp.HarpCaller("localhost")
   job = rpc.host("web01.example.net", max_exec_time = 60).run_foo()
   job = rpc.host("web01.example.net", timeout = 60).run_foo()

``max_exec_time`` specifies how long (in seconds) the job can run in total
before it is cancelled. ``timeout`` for jobs that return stream result
specifies maximum time between consecutive partial results. For jobs that only
return end result, ``timeout`` works in the same way as ``max_exec_time``.

Call queues
-----------

Execution of remote calls can be organized in queues. A queue is identified by
its *name*, which is a dictionary with arbitrary content supplied at call
time. This way the jobs can be grouped by target host, procedure, or some
(possibly unrelated to the call) data. A queue is created by the first call
with the queue's name and is deleted when the last job from the queue
terminates.

By default only one job from a queue can be running at the sime time. This can
be configured at queue's creation time by setting *concurrency level* to the
desired number of simultaneously running jobs. A queue retains the same
concurrency level throughout its whole life.

A job can belong to one queue or to no queue at all. ``timeout`` and
``max_exec_time`` don't count the time the job spent waiting for its turn in
the queue.

.. code-block:: python

   import harp
   rpc = harp.HarpCaller("localhost")
   hostname = "web01.example.net"
   queue = { "host": hostname, "command": "foo" } # per-host queue
   # run at most 3 jobs in this queue
   job = rpc.host(hostname, queue = queue, concurrency = 3).run_foo()

   print job.submit_time()
   print job.start_time()  # `None' if the job still waits in the queue

Job information
---------------

User can retrieve from HarpCaller various information about a call job. This
includes the names of target host and procedure (:meth:`job.host()
<harp.RemoteCall.host()>`, :meth:`job.procedure()
<harp.RemoteCall.procedure()>`), arguments (:meth:`job.args()
<harp.RemoteCall.args()>`), and time of job submission
(:meth:`job.submit_time() <harp.RemoteCall.submit_time()>`), start
(:meth:`job.start_time() <harp.RemoteCall.start_time()>`), and termination
(:meth:`job.end_time() <harp.RemoteCall.end_time()>`).

User can also attach an additional information to a remote call. This
information will not be interpreted by HarpCaller in any way and its meaning
is at the user's discretion.

.. code-block:: python

   import harp
   rpc = harp.HarpCaller("localhost")
   job_info = { ... } # JSON-serializable data
   job = rpc.host("web01.example.net", info = info).run_foo()

   job = rpc.job("8ec71d6b-28d1-4ce2-aa23-f3ea7887beda")
   print json.dumps(job.info())

Interpreting errors
-------------------

**TODO**: Error reporting from HarpCaller needs to be cleaned up. There's no
unified way to identify the cause of an error for now.


Using :manpage:`harpd(8)`
=========================

Sometimes running a request dispatcher may be an unnecessary overhead. For
these cases, :mod:`harp` offers API for communicating with :manpage:`harpd(8)`
directly.

.. code-block:: python

   import harp
   server = harp.HarpServer(
       host = "10.8.16.22",
       user = "example_user",
       password = "example_password",
       ca_file = "/path/to/ca_certificates.crt",
   )

   value = server.run_foo()
   print value

Since there's no proxy that would save call results for later use, all calls
are synchronous.

If the called procedure only returns an end result, ``value`` from above
example will be a JSON-serializable object and no further work is needed to
consume it. If the procedure returns partial results, ``value`` will be an
iterable object (:class:`harp.HarpStreamIterator`):

.. code-block:: python

   import harp
   server = harp.HarpServer(...)

   for record in server.run_stream():
       if isinstance(record, harp.Result):
           end_result = record
           break
       else:
           print record
   # do something with `end_result.value'

Unlike in the communication with HarpCaller, end result is included in the
iterator (and similarly, errors are thrown from the iterator as well). To tell
the partial results and end result apart, end result is wrapped in
:class:`harp.Result` container and is always the last value.

When an error is encountered, an exception (a subclass of
:exc:`harp.HarpException`) is thrown. In particular, an exception thrown by
the remote procedure is raised as :exc:`harp.RemoteException`.

**NOTE**: When calling a remote :manpage:`harpd(8)` from a procedure under
another :manpage:`harpd(8)` instance, remember not to confuse the container
classes :class:`harp.Result` and :class:`harpd.proc.Result`. They cannot be
used interchangeably, though they have similar structure and symmetrical
purposes.


See Also
========

* :manpage:`harp(3)`
* :manpage:`harpd(8)`
* :manpage:`harpcallerd(8)`
