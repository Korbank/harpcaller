*****************
Python client API
*****************

.. _client-lib-examples:

Synopsis
========

HarpCaller interaction
----------------------

.. code-block:: python

   import json
   import harp

   rpc = harp.HarpCaller("localhost")

   host = rpc.localhost(queue = {"foo": "bar"}, max_exec_time = 15)
   # or: `host = rpc.host(host = "localhost", queue = ...)'
   # or simply: `host = rpc.localhost', if no job configuration is needed
   job = host.stream_infinity()
   for msg in job.follow(since = 0):
       print json.dumps(msg)

   print job.id()
   print job.result()

   result = rpc("localhost").return_immediate("bar", "baz").get()

   job_id = "3f22e0d4-c8ed-11e5-8d66-001e8c140268"
   result = rpc.job(job_id).result()
   if result is harp.CALL_NOT_FINISHED:
       print "still running"
   elif result is harp.CALL_CANCELLED:
       print "cancelled"
   elif ...

:manpage:`harpd(8)` interaction
-------------------------------

.. code-block:: python

   import json
   import harp

   server = harp.HarpServer(
       host = "localhost",
       user = "username",
       password = "secret",
   )
   print server.current_time()
   for msg in server.logs_in_next_minutes(10):
       if isinstance(msg, harp.Result):
           # last value, nothing more will be returned
           print json.dumps(msg.value)
       else:
           print "log message:", json.dumps(msg)


Description
===========

:mod:`harp` is a Python interface to talk to HarpCaller: send a call request,
check call status, retrieve its results, and so on. This part of the API is
asynchronous, so it can easily be used in a web application, even if the
remote procedures that are called take long time to finish.

:mod:`harp` allows also to talk directly to :manpage:`harpd(8)` instances, to
provide enough tools for scenarios when running :manpage:`harpcallerd(8)`
would be too expensive or troublesome. This part of the API is synchronous, so
all calls block until the called remote procedure finishes.


.. _client-lib-api:

Python interface
================

.. automodule:: harp

