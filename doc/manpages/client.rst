*****************
Python client API
*****************

.. _client-lib-examples:

Example usage
=============

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

:program:`harpd` interaction
----------------------------

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


.. _client-lib-api:

Python interface
================

.. automodule:: harp

