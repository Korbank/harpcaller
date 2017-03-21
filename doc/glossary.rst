********
Glossary
********

.. glossary::

    call dispatcher
        HarpCaller daemon, :manpage:`harpcallerd(8)`, acting as a proxy
        between clients and daemons (:manpage:`harpd(8)`). Dispatcher stores
        call results and can provide them at later time.

    daemon
        :manpage:`harpd(8)`, which receives *RPC calls*, executes appropriate
        function, and responds with its result. Code of functions that can be
        called is part of the daemon's configuration.

    client library
        Python :mod:`harp` module that communicates with HarpCaller and
        :manpage:`harpd(8)` daemons.

    queue
        List of *jobs* to carry out. At most N jobs are running at a single
        time, with N being queue's *concurrency level*, newer jobs waiting for
        some already running job to terminate.

        .. glossary::

            concurrency level
                Maximum number of jobs that can run simultaneously in a given
                queue.

    RPC call
        A request sent to a :manpage:`harpd(8)` instance. The request carries
        name of the procedure to be called and arguments to the procedure.

    job
    call job
        HarpCaller's record about *RPC call*.

        .. glossary::

            identifier
                UUID (string representation) that is used to tell the jobs
                apart.

            end result
                Value that was returned by called function. Receiving the end
                result marks the termination of RPC call (and, in turn, the
                call job). End result may be preceded by *stream result*.

            stream result
            partial results
                Sequence of values returned by called function. None of these
                values denote termination of RPC call. Partial results are
                passed to client immediately after being produced, without
                waiting for the function to terminate.

            error
                Operational problem, like network or disk error, unknown job,
                or unknown host.

            exception
                An exception raised by the function executed for RPC call.
                An exception usually means that there is some problem with
                function's code.

