***********************
HarpCaller architecture
***********************

``harpcaller`` application
==========================

**TODO**

Daemonization
=============

``indira`` application
----------------------

**TODO**

administrative protocol
-----------------------

**TODO**


Communication protocol
======================

Protocol is based on a line-wise JSON. Each message is serialized to a single
line. The protocol is asynchronous: client receives job ID in response to
a call request and is expected to check status of the job later.

Call request
------------

.. code-block:: none

   {"harpcaller": 1, "host": "...", "procedure": "...", "arguments": []}
   {"harpcaller": 1, "host": "...", "procedure": "...", "arguments": [...]}
   {"harpcaller": 1, "host": "...", "procedure": "...", "arguments": {...}}
   {"harpcaller": 1, ..., "timeout": integer, "max_exec_time": integer}
   {"harpcaller": 1, ..., "queue": {"name": {...}, "concurrency": C}}
   {"harpcaller": 1, ..., "info": ...}

Call may either use positional arguments or named arguments.
Call with no arguments is indicated with an empty list.

Request may set timeout, maximum execution time, or both. Timeout is maximum
time allowed between consequent messages (mainly: time when next stream
message is expected); maximum execution time is total time between issuing
a call request and receiving result. For procedures that do not stream their
result, the two are equivalent.

Request may set a queue where the call will wait for its turn. Queues are
named, where the name is an arbitrary hash object. Queue may specify also
its desired concurrency level (number of calls that are executed at the same
time; if there are more calls in the queue than queue's concurrency level,
some of them will be kept waiting until one or more currently executing calls
terminate).

Request may set an additional information about the job. This information is
opaque to HarpCaller and will be returned as-is in response to
``"get_status"`` request. If this field was not specified, null is used as the
value.

Reply:

.. code-block:: none

   {"harpcaller": 1, "job_id": "..."}


Job cancellation
----------------

.. code-block:: none

   {"harpcaller": 1, "cancel": "..."}

Value of ``"cancel"`` field is job ID.

Reply:

.. code-block:: none

   {"cancelled": true | false}

True is returned if the job was running and was stopped.
False is returned if the job was terminated already or not existent at all.


Receiving call result
---------------------

.. code-block:: none

   {"harpcaller": 1, "get_result": "..."}
   {"harpcaller": 1, "get_result": "...", "wait": true | false}

Value of ``"get_result"`` is job ID.

``"wait"`` field set to false indicates that the dispatcher should reply
immediately, even if the job didn't finish yet. ``"wait"`` set to true is
equivalent to not specifying it at all.

Reply:

* ``{"no_result": true}`` -- call not terminated yet (only relevant to
  ``"wait":false``)
* ``{"result": ...}`` -- call returned successfully
* ``{"exception": {"type": "...", "message": "...", "data": ...}}`` -- call
  returned with an exception ``"type"`` is the kind of the exception,
  ``"message"`` contains human-readable description, ``"data"`` is
  a (preferably structured) information to help troubleshooting; ``"data"``
  field is optional
* ``{"cancelled": true}`` -- job was cancelled before it returned any value
* ``{"error": {"type": "os_error", "message": "..."}}`` -- connection to Harp
  daemon failed because of an error on OS side
* ``{"error": {"type": "network_error", "message": "..."}}`` -- connection to
  Harp daemon failed because of a network error (connection refused,
  connection broken, network timeout, etc.)
* ``{"error": {"type": "protocol_error", "message": "..."}}`` -- Harp daemon
  responded to dispatcher's request with garbage


Reading full status of a job
----------------------------

.. code-block:: none

   {"harpcaller": 1, "get_status": "..."}

Value of ``"get_status"`` is job ID.

Reply has three types of information: what was called, when it was called, and
additional information passed by the caller in the unmodified form:

.. code-block:: none

   { "call": {"host": "...", "procedure": "...", "arguments": ...},
     "time": {"submit": integer, "start": integer, "end": integer},
     "info": ... }

Value of ``"submit"`` is always set to a timestamp, but ``"start"`` and
``"end"`` may be null if the job wasn't started or hasn't ended yet (job
cancelled before it could start will have ``"start"`` ``null`` with ``"end"``
set).

If a non-exsiting job ID was requested, an error is returned:

.. code-block:: none

   {"error": {"type": "invalid_jobid", "message": "..."}}

For any other error, a message similar to errors in receiving call results is
sent:

.. code-block:: none

   {"error": {"type": "...", "message": "..."}}


Reading result stream
---------------------

.. code-block:: none

   {"harpcaller": 1, "follow_stream": "..."}
   {"harpcaller": 1, "follow_stream": "...", "recent": integer}
   {"harpcaller": 1, "follow_stream": "...", "since": integer}

Value of ``"follow_stream"`` is job ID.

This request is used mainly to receive continuous stream of packets that call
produces, as soon as they are produced.

``"recent"`` specifies how many messages already collected by dispatcher
should be returned additionally to all messages from now on, so the client can
build some context from the stream.

``"since"`` specifies the first packet to return. Value of 0 returns all the
stream. ``"since"`` and ``"recent"`` fields are mutually exclusive.

Providing neither ``"recent"`` nor ``"since"`` has the same meaning as
specifying ``"recent":0``.

Reply is a stream of messages, one at a line:

.. code-block:: none

   {"packet": integer, "data": ...}

Packet number is a number incremented by 1 for each packet, with 0 being the
first packet in job's stream (that is, it's an absolute position). This is the
identifier to be used in ``"since"`` field.

The end of stream is indicated by message carrying a call result (either value
or exception), information of the job being cancelled, or an error. In other
words, any of the replies to ``"get_result"`` except ``"no_result"``.


Reading result stream page-wise
-------------------------------

.. code-block:: none

   {"harpcaller": 1, "read_stream": "..."}
   {"harpcaller": 1, "read_stream": "...", "recent": integer}
   {"harpcaller": 1, "read_stream": "...", "since": integer}

Value of ``"read_stream"`` is job ID.

This request is used mainly to read a sequence of packets produced until now,
and then, after an interval, read the next portion of packets with next
request. This mode of operation should be easier to use in a web application
than ``"follow_stream"``.

Fields ``"recent"`` and ``"since"`` have the same meaning as for
``"follow_stream"`` request.

Providing neither ``"recent"`` nor ``"since"`` has the same meaning as
specifying ``"since":0`` (note: difference from ``"follow_stream"`` request).

Reply is a stream of messages, one at a line, the same as in
``"follow_stream"``, with a one additional message that can terminate stream:

.. code-block:: none

   {"continue": true}

This message indicates that all the currently available stream packets were
returned, but the job hasn't terminated yet, so there's still something to
read in the future (call result at least).

