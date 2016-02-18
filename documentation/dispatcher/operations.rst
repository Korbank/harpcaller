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
    harpcallerd [options] status
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

.. program:: harpcallerd status

``harpcallerd status [--wait [--timeout=SECONDS]]``
   Check HarpCaller daemon's status (``"running"`` or ``"not running"``),
   possibly waiting for HarpCaller to start. If the controlling socket does
   not exist at this point yet and :option:`--wait` was specified, command
   waits for it to appear (at most for *SECONDS*).

   .. option:: --wait

      Wait for daemon to confirm successful start.

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

The configuration file (default: :file:`/etc/harpcaller/harpcaller.toml`) is
in `TOML <https://github.com/toml-lang/toml>`_ format.

First, example config:

.. code-block:: ini

    # network
    listen = ["*:3502"]
    #ca_file = "/etc/harpcaller/ca_certs.pem"
    known_certs_file = "/etc/harpcaller/known_certs.pem"

    # jobs
    stream_directory = "/var/lib/harpcaller/stream/"
    default_timeout = 600
    max_exec_time = 600

    # hosts registry
    host_db_script = "/etc/harpcaller/update-hosts"
    host_db = "/var/lib/harpcaller/hosts.db"
    host_db_refresh = 900

    # logging
    log_handlers = ["harpcaller_syslog_h"]

    [erlang]
    node_name = "harpcaller"
    name_type = "longnames"
    #cookie_file = "/etc/harpcaller/cookie.txt"
    distributed_immediate = false
    error_logger_handlers = []

.. ** Vim's syntax sucks in code blocks with asterisk

The config has two sections: main and ``[erlang]``. Parameters in main section
control the daemon behaviour. Section ``[erlang]`` is responsible for
configuring Erlang/OTP, an addition to :ref:`harpcaller-beam-opts`.

Main section
~~~~~~~~~~~~

``listen``
   List of addresses to listen on for requests. A listen address has form of
   ``"<bind-address>:<port>"``, with ``<bind-address>`` being a hostname, IP
   address, or ``*`` to bind to any addresses.

``ca_file``, ``known_certs_file``
   These two parameters control how HarpCaller will verify called
   :program:`harpd`.

   If ``ca_file`` is specified, :program:`harpd`'s certificate needs to be
   signed properly by one of the CAs from the file (or a sub-CA, with proper
   certificate chain). *commonName* attribute is not verified yet.

   If ``known_certs_file`` is specified, :program:`harpd`'s certificate needs
   to be whitelisted in this file.

   If both files are specified, a certificate satisfying any of the above
   criteria is accepted. If neither is specified, any certificate is accepted.

``stream_directory``
   Directory to store information about call jobs and their results (streamed
   and returned).

``default_timeout``
   Default timeout (seconds) for waiting for job's activity (either returned
   result or next packet from streamed result). Request may specify longer
   timeout if needed.

``max_exec_time``
   Maximum time (seconds) the job can take. Any job longer than this will be
   aborted. Request may specify different execution time, but can't make it
   higher than set in config.

``host_db``
   Path to a file where hosts registry will store information about known
   hosts, collected from running ``host_db_script``.

``host_db_script``
   Script to fill hosts registry. It should print JSON hashes, one per line,
   each containing address and port to communicate with a host. See
   :ref:`harpcaller-hosts-reg-filler` to for expected output format.

``host_db_refresh``
   Frequency (seconds) of running ``host_db_script`` to refresh hosts
   registry.

``log_handlers``
   List of Erlang modules to handle log messages generated by HarpCaller.

   HarpCaller comes with two such modules: ``harpcaller_stdout_h``, which
   prints the logs to *STDOUT*, and ``harpcaller_syslog_h``, which sends the
   logs to local syslog.

.. _harpcaller-beam-opts:

Erlang VM configuration
-----------------------

.. %%! -args_file /etc/harpcaller/erlang.args

Parameters of Erlang virtual machine can be supplied in
:file:`/etc/harpcaller/erlang.args`. It's the same command line parameters as
for ``erl`` command, and in fact, this is achieved by including a file with
``-args_file``.

In most uses it should not be necessary to fill this file.

.. _harpcaller-hosts-reg-filler:

Hosts registry filler script
----------------------------

Registry filler script is executed in regular intervals to fill the database
of hosts that are available for RPC calls. This script is supposed to write
JSON hashes with information about hosts, one JSON per line.

Filler script can be written in any language (e.g. in Python or shell), as
long as it can be executed as a command. It can safely assume that it won't be
called such that two instances would run at the same time (it can take longer
than ``host_db_refresh`` to execute the script). Any not recognized line will
be ignored.

If the script exits with non-zero code, hosts registry *will not* be updated.

The information the script prints should contain name of the host, its IP
address and port, and credentials (user and password) to authenticate request.
A single JSON hash could look like this (broken down for reading convenience):

.. code-block:: yaml

    {
      "hostname": "web01.example.net",
      "address": "10.8.14.2",
      "port": 4306,
      "credentials": {
        "user": "rpc-system",
        "password": "caixaudakuPus6yo"
      }
    }

