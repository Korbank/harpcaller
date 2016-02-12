***************************
Operating HarpCaller daemon
***************************

Command line
============

Usage
-----

Controlling the daemon (:ref:`ref <harpcaller-daemon>`):

.. code-block:: none

    harpcallerd [options] start
    harpcallerd [options] wait-for-start
    harpcallerd [options] stop
    harpcallerd [options] reload-config
    harpcallerd [options] dist-erl-start
    harpcallerd [options] dist-erl-stop

Controlling call jobs (:ref:`ref <harpcaller-jobs>`):

.. code-block:: none

    harpcallerd [options] list
    harpcallerd [options] cancel <job-id>
    harpcallerd [options] queue-list
    harpcallerd [options] queue-list <queue-name>
    harpcallerd [options] queue-cancel <queue-name>

Hosts registry (:ref:`ref <harpcaller-hosts>`):

.. code-block:: none

    harpcallerd [options] hosts-list
    harpcallerd [options] hosts-refresh


Commands
--------

.. program:: harpcallerd

Erlang VM does not support unix signals well, so to communicate with daemon,
some other channel is needed. This is achieved by using an administrative
socket. It actually gives more possibilities than using signals, so HarpCaller
offers much wider administrative command line than typical daemon.

Following option is common to all the commands in later sections:

.. option:: --socket=PATH

   Path to controlling socket, through which administrative commands can be
   sent. Defaults to :file:`/var/run/harpcaller/harpcaller.sock`.

.. _harpcaller-daemon:

Controlling the daemon
~~~~~~~~~~~~~~~~~~~~~~

.. program:: harpcallerd start

``harpcallerd start [--debug] [--config=FILE] [--pidfile=FILE]``
   Start HarpCaller daemon.

   .. option:: --debug

      Start the daemon with `Erlang SASL application
      <http://erlang.org/doc/apps/sasl/index.html>`_ started. This prints
      Erlang boot progress to screen, which makes it easier to debug any
      problems with *harpcaller* application.

   .. option:: --config=FILE

      Path to HarpCaller's configuration file. Defaults to
      :file:`/etc/harpcaller/harpcaller.toml`.

   .. option:: --pidfile=FILE

      File to write PID to. Since all communication is passed through
      controlling socket, this is mostly informative.

.. program:: harpcallerd wait-for-start

``harpcallerd wait-for-start [--timeout=SECONDS]``
   Wait for HarpCaller daemon to start. If the controlling socket does not
   exist at this point yet, command waits for it to appear (at most for
   *SECONDS*).

   .. option:: --timeout=SECONDS

      How long the command should wait for daemon to start. If not specified,
      command waits infinitely.

.. program:: harpcallerd stop

``harpcallerd stop [--timeout=SECONDS] [--print-pid]``
   Shutdown the running daemon. The command may print daemon's PID, so the
   caller can wait for it to terminate (e.g. using ``kill -0 $PID``).

   .. option:: --timeout=SECONDS

      How long the command should wait for daemon to shutdown. If not
      specified, command waits infinitely.

   .. option:: --print-pid

      If specified, PID reported by the daemon is printed to screen.

.. program:: harpcallerd reload-config

``harpcallerd reload-config``
   Reload :ref:`configuration file <harpcaller-config-file>`.

   **NOTE**: This command is not implemented yet.

.. program:: harpcallerd dist-erl-start

``harpcallerd dist-erl-start``
   Start Erlang networking (`Distributed Erlang
   <http://erlang.org/doc/reference_manual/distributed.html>`_).

   For this command to succeed, `epmd(1)
   <http://erlang.org/doc/man/epmd.html>`_ must already be running and
   networking not be configured with :ref:`VM options file
   <harpcaller-beam-opts>`.

.. program:: harpcallerd dist-erl-stop

``harpcallerd dist-erl-stop``
   Shutdown Erlang networking (`Distributed Erlang
   <http://erlang.org/doc/reference_manual/distributed.html>`_).

   For this command to succeed, networking must not be configured with
   :ref:`VM options file <harpcaller-beam-opts>`.

.. _harpcaller-jobs:

Controlling call jobs
~~~~~~~~~~~~~~~~~~~~~

.. program:: harpcallerd list

``harpcallerd list``
   List jobs currently running or waiting for their turn in some queue.

   Output is a list of JSON hashes, one per line. The hashes have following
   structure (broken down for reading convenience):

   .. code-block:: yaml

      {
        "job": "9e03ca7a-bdcb-4bc1-8a56-0f17b310a556",
        "call": {
          "host": "web01.example.net",
          "procedure": "some.procedure",
          "arguments": [...]
        },
        "time": {
          "submit": 1455282411,
          "start": 1455282411,
          "end": null
        }
      }

   Job identifier (``"job"`` value) is always in UUID string format.

.. program:: harpcallerd cancel

``harpcallerd cancel <job-id>``
   Cancel specific job.

.. program:: harpcallerd queue-list

``harpcallerd queue-list``
   List queues that have any job running or waiting.

   Queue name is a JSON hash, so the output is a list of JSON hashes, one per
   line.

.. program:: harpcallerd queue-list-queues

``harpcallerd queue-list <queue-name>``
   List content of specific queue.

   Output is similar to what ``harpcallerd list`` prints. Obviously, a job
   that was submitted but not started yet still waits in a queue.

   **NOTE**: Given the queue name is a JSON, you may need to use single quotes
   in your shell ``'...'`` around the name.

.. program:: harpcallerd queue-cancel

``harpcallerd queue-cancel <queue-name>``
   Cancel all the jobs in specific queue.

   **NOTE**: Given the queue name is a JSON, you may need to use single quotes
   in your shell ``'...'`` around the name.

   This command is not an atomic operation, so if a job is submitted to the
   queue in the same moment ``queue-cancel`` was called, the queue may end up
   not being deleted and re-created. This may affect queue's concurrency
   level.

.. _harpcaller-hosts:

Hosts registry
~~~~~~~~~~~~~~

.. program:: harpcallerd hosts-list

``harpcallerd hosts-list``
   List hosts known to the hosts registry, and thus available to RPC call
   requests.

   Output is a list of JSON hashes, one per line, which look like this:

   .. code-block:: yaml

      {"hostname": "web01.example.net", "address": "10.8.14.2", "port": 4306}

   Note that while this output is similar to
   :ref:`registry filler script's <harpcaller-hosts-reg-filler>`, but it lacks
   credentials.

.. program:: harpcallerd hosts-refresh

``harpcallerd hosts-refresh``
   Order the HarpCaller to :ref:`refresh its hosts registry
   <harpcaller-hosts-reg-filler>` outside the schedule.


Configuration
=============

.. _harpcaller-config-file:

Configuration file
------------------

.. _harpcaller-beam-opts:

Erlang VM configuration
-----------------------

:file:`/etc/harpcaller/erlang.args`

``%%! -args_file /etc/harpcaller/erlang.args``

.. _harpcaller-hosts-reg-filler:

Hosts registry filler script
----------------------------

