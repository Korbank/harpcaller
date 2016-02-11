===============
Harp RPC system
===============

------------
Architecture
------------

HarpRPC system consists of four parts: RPC daemon running on each of the
settopboxes, RPC daemon running on each of the streamers, RPC dispatcher
daemon running somewhere (typically along with Avios Panel), and Python client
library to talk to HarpCaller.

Client library is talks to HarpCaller to issue new call and to check call
result. There are two modes of returning result: single asynchronous response
and streamed response (mode in use depends on procedure definition). An
asynchronous call is trivialy convertible to a synchronous call on client
side.

HarpCaller connects to RPC daemon that runs on a streamer, issues a call, and
synchronously reads the response (either a single value or streamed result).
It allows clients to read the call state and any streamed data associated with
the call. Dispatcher allows also to receive information about the call
(including its result) after the call was terminated.

Harp daemon serves two purposes. First is to execute a procedure directly on
a streamer (e.g. reloading configuration). Second is to forward the call to
settopbox and call result back to the caller (typically the dispatcher).

-----------------
Repository layout
-----------------

daemon/      -- Harp daemon, to be deployed on streamers
dispatcher/  -- HarpCaller, to be deployed along with Avios Panel
harp/        -- HarpCaller client, to be used in Avios Panel

RPC daemon for settopboxes is in a different repository.
