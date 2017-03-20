************************
Harp daemon architecture
************************

**TODO**

Operator-facing modules
=======================

* :mod:`harpd.proc`
* :mod:`harpd.auth.passfile`
* :mod:`harpd.auth.inconfig`

Internal modules
================

.. automodule:: harpd.daemon

.. automodule:: harpd.module

.. automodule:: harpd.auth


Communication protocol
======================

Protocol is based on a line-wise JSON. Each message is serialized to a single
line. The protocol is synchronous, i.e., client waits for a response after
each request.

Since HarpRPC is not planned to be a heavy duty service, requests are intended
to be carried in separate connections. Cancelling a request boils down to
simply closing the connection before receiving result.

Call request
------------

Request
~~~~~~~

Call with positional arguments:

.. code-block:: none

   {"harp": 1, "procedure": "...", "arguments": [...], "auth": {"user": "...", "password": "..."}}

Call with named arguments:

.. code-block:: none

   {"harp": 1, "procedure": "...", "arguments": {...}, "auth": {"user": "...", "password": "..."}}

Call with no arguments:

.. code-block:: none

   {"harp": 1, "procedure": "...", "arguments": [], "auth": {"user": "...", "password": "..."}}

Each call request needs to be authenticated. Currently, the only
authentication method is username+password pair.

Acknowledgement
~~~~~~~~~~~~~~~

Call request is immediately acknowledged with a message indicating whether
there will be a streamed result or not. The message looks as follows:

.. code-block:: none

   {"harp": 1, "stream_result": true | false}

Transport-level and daemon operational errors
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If the request is ill-formatted, contains invalid data, points to
a non-existing function, carries incorrect number of arguments, or there are
other server-side problems with execution of the procedure, error is returned
instead of or after acknowledgement (possibly in the middle of stream result):

.. code-block:: none

   {"harp": 1, "error": {"type": "...", "message": "...", "data": ...}}

``"type"`` indicates the kind of the error, in similar fashion as ``errno`` in
unix system calls (except for being string). ``"message"`` is more detailed
string that is readable to human. ``"data"`` key is optional and may carry any
value that could help in troubleshooting. Structured data (i.e. JSON object)
is preferred.

Predefined values of ``"type"`` are:

* ``"parse_error"`` -- request line is not a valid JSON
* ``"invalid_protocol"`` -- ``"harp"`` field from the request is missing or
  carries wrong value
* ``"invalid_request"`` -- any other error with request structure
* ``"auth_error"`` -- user doesn't exist or password is invalid
* ``"no_such_procedure"`` -- requested procedure does not exist
* ``"procedure_loading_error"`` -- requested procedure could not be loaded
* ``"invalid_argument_list"`` -- argument list does not match the signature of
  the requested procedure

Other values of ``"type"`` are allowed.

Response
--------

After acknowledgement message, one or more messages with the result is sent.

Single result:

.. code-block:: none

   {"result": ...}

Streamed result:

.. code-block:: none

   {"stream": ...}
   {"stream": ...}
   ...
   {"result": ...}

Exception raised in the procedure is reported by sending following message
instead of ``{"result":...}``:

.. code-block:: none

   {"exception": {"type": "...", "message": "...", "data": ...}}

Meaning and format of these fields is similar to protocol-level error
message. ``"data"`` is an optional field here as well.

Streamed result always ends with either ``{"result":...}``,
``{"exception":...}``, or ``{"error":..., "harp": 1}`` message.
