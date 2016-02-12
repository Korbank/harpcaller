*********************
Operating Harp daemon
*********************

.. program:: harpd

Command line
============

Usage
-----

.. code-block:: none

    harpd [options]

Available options
-----------------

.. option:: -c FILE, --config=FILE

   path to YAML file with general configuration; defaults to
   :file:`/etc/harpd/harpd.conf`

.. option:: -r FILE, --procedures=FILE

   path to Python file with procedures to be exposed; defaults to
   :file:`/etc/harpd/harpd.py`

.. option:: -l FILE, --logging=FILE

   path to YAML file with logging configuration

.. option:: -d, --daemon

   detach from terminal and run as a daemon

.. option:: -p FILE, --pidfile=FILE

   write PID to specified file (typically used with :option:`--daemon`)


Configuration
=============

General configuration
---------------------

There are two main categories of options to be set in
:file:`/etc/harpd/harpd.conf` file. One is network configuration, like bind
address and port or SSL/TLS certificate and private key, the other is request
authentication.

When specifying a X.509 certificate with CA chain, you should put in the file
the leaf certificate first, followed by the certificate of CA that signed the
leaf, followed by higher-level CA (if any), up until the root-level CA.
Obviously, root CA needs to be in trusted store on client side, so you don't
need to add this one.

Authentication specifies a field ``"module"``, which is a name of a Python
module that will be used to authenticate requests. See
:ref:`harpd-auth-modules` for list of modules shipped with :program:`harpd`.

Configuration for :program:`harpd` should look like this (YAML):

.. code-block:: yaml

    network:
      #address: 127.0.0.1
      port: 4306
      certfile: /etc/harpd/harpd.cert.pem
      keyfile:  /etc/harpd/harpd.key.pem

    authentication:
      module: harpd.auth.passfile
      file: /etc/harpd/users.txt


Logging
-------

:file:`logging.yaml` is a configuration suitable directly for
:func:`logging.config.dictConfig()` function, serialized to YAML. To read in
more detail about how logging works, see:

* Python :mod:`logging`: `<https://docs.python.org/2/library/logging.html>`_
* Configuring :mod:`logging`: `<https://docs.python.org/2/library/logging.config.html>`_
* Configuring :mod:`logging` with dictionary:
  `<https://docs.python.org/2/library/logging.config.html#logging-config-dictschema>`_

If no logging configuration file was specified, :program:`harpd` defaults to
log to *STDERR*.

Logging configuration could look like following:

.. code-block:: yaml

    version: 1
    root:
      level: NOTSET
      handlers: [stderr]
    formatters:
      terse:
        format: "%(message)s"
      timestamped:
        format: "%(asctime)s %(message)s"
        datefmt: "%Y-%m-%d %H:%M:%S"
      syslog:
        format: "harpd[%(process)d]: %(message)s"
    handlers:
      syslog:
        class: logging.handlers.SysLogHandler
        address: /dev/log  # unix socket on Linux
        facility: daemon
        formatter: syslog
      stderr:
        class: logging.StreamHandler
        formatter: terse
        stream: ext://sys.stderr


Exposed procedures
------------------

To expose some Python procedures for RPC calls, you need to write a Python
module. The functions you want to expose you mark with
:func:`harpd.proc.procedure()` or :func:`harpd.proc.streaming_procedure()`
decorator, and that's pretty much it.

Every call to such exposed function will be carried out in a separate unix
process.


Writing procedures
==================

The module with procedures *will not* be loaded in typical way, so you should
not depend on its name (:obj:`__name__`) or path (:obj:`__file__`). Otherwise,
it's a regular module.

Decorators :func:`harpd.proc.procedure()` and
:func:`harpd.proc.streaming_procedure()` merely create a wrapper object that
is an instance of :class:`harpd.proc.Procedure` or
:class:`harpd.proc.StreamingProcedure`. Instead of using the decorators, you
may write a subclass of one or the other, and create its instance stored in
a global variable. Note that the instance is callable, like a regular
function.

Wrapper objects are created just after the daemon starts, when the module with
procedures is loaded, and are carried over the :func:`fork()` that puts each
request in a separate process. Destroying the objects in parent and child
processes is a little tangled, so don't depend on :meth:`__del__()` method.

.. automodule:: harpd.proc

.. _harpd-auth-modules:

Auth database backends
======================

.. automodule:: harpd.auth.passfile

.. automodule:: harpd.auth.inconfig

