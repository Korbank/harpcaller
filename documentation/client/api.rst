*****************
Python client API
*****************

.. _client-lib-examples:

Example usage
=============

.. code-block:: python

   import json
   import korrpc

   rpc = korrpc.KorRPC("localhost")

   job = rpc(host = "localhost", queue = {"foo": "bar"}, max_exec_time = 15).stream_infinity()
   for msg in job.follow(since = 0):
       print json.dumps(msg)

   print job.id()
   print job.result()

   result = rpc("localhost").return_immediate("bar", "baz").get()

   job_id = "3f22e0d4-c8ed-11e5-8d66-001e8c140268"
   result = rpc.job(job_id).result()
   if result is korrpc.CALL_NOT_FINISHED:
       print "still running"
   elif result is korrpc.CALL_CANCELLED:
       print "cancelled"
   elif ...


.. _client-lib-api:

Python interface
================

.. automodule:: korrpc

