%%%---------------------------------------------------------------------------
%%% @doc
%%%   Call queue handler.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_call_queue).

-behaviour(gen_server).

%% public interface
-export([enqueue/2]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type queue_name() :: term().

-record(state, {
  q :: ets:tab(),     % running and queued objects
  qopts :: ets:tab(), % queue options (just concurrency level at the moment)
  qpids :: ets:tab()  % pid->{queue+status}
}).

-record(qopts, {
  name :: queue_name(),
  running :: non_neg_integer(), % when 0, queue is deleted
  concurrency :: pos_integer()  % running =< concurrency
}).

-record(qentry, {
  pid :: pid(),
  monref :: reference(),
  qref :: reference()
}).

-record(qpid, {
  key :: {pid(), reference()},
  q :: queue_name(),
  qref :: reference(),
  state :: queued | running
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Request a place in a named queue.

-spec enqueue(queue_name(), pos_integer()) ->
  reference().

enqueue(QueueName, Concurrency) when is_integer(Concurrency), Concurrency > 0 ->
  gen_server:call(?MODULE, {enqueue, self(), QueueName, Concurrency}).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start queue process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start queue process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init(_Args) ->
  Queue = ets:new('queue', [bag]),
  QueueOpts = ets:new(queue_opts, [set, {keypos, #qopts.name}]),
  QueuePids = ets:new(queue_pids, [set, {keypos, #qpid.key}]),
  State = #state{
    q = Queue,
    qopts = QueueOpts,
    qpids = QueuePids
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{q = Queue, qopts = QueueOpts,
                                qpids = QueuePids}) ->
  % TODO: what if there's still stuff running and/or queued?
  ets:delete(Queue),
  ets:delete(QueueOpts),
  ets:delete(QueuePids),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({enqueue, Pid, QueueName, Concurrency} = _Request, _From,
            State = #state{q = Queue, qopts = QueueOpts, qpids = QueuePids}) ->
  MonRef = monitor(process, Pid),
  QRef = make_ref(),
  Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
  PidEntry = #qpid{key = {Pid, MonRef}, q = QueueName, qref = QRef},
  % create a queue if it doesn't exist already
  ets:insert_new(QueueOpts, #qopts{
    name = QueueName,
    running = 0,
    concurrency = Concurrency
  }),
  case ets:lookup(QueueOpts, QueueName) of
    [#qopts{running = N, concurrency = C}] when N < C ->
      % queue with spare room to run a task
      ets:update_counter(QueueOpts, QueueName, {#qopts.running, 1}),
      ets:insert(QueuePids, PidEntry#qpid{state = running}),
      ets:insert(Queue, {{running, QueueName}, Entry}),
      make_running(Entry),
      ok;
    [#qopts{running = N, concurrency = C}] when N >= C ->
      % queue full of running tasks
      ets:insert(QueuePids, PidEntry#qpid{state = queued}),
      ets:insert(Queue, {{queued, QueueName}, Entry}),
      ok
  end,
  {reply, QRef, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({'DOWN', MonRef, process, Pid, _Info} = _Message,
            State = #state{q = Queue, qopts = QueueOpts, qpids = QueuePids}) ->
  case ets:lookup(QueuePids, {Pid, MonRef}) of
    [] ->
      % it wasn't a process monitored because of queue
      ignore;
    [#qpid{q = QueueName, qref = QRef, state = running}] ->
      Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
      ets:delete_object(Queue, {{running, QueueName}, Entry}),
      case ets:lookup(Queue, {queued, QueueName}) of
        [] ->
          % if nothing is left for this queue, check how many processes are
          % running there, and if none (this was the last one), drop the queue
          case ets:update_counter(QueueOpts, QueueName, {#qopts.running, -1}) of
            N when N > 0 -> ok;
            0 -> ets:delete(QueueOpts, QueueName)
          end;
        [{{queued, QueueName}, NextEntry} | _] ->
          ets:delete_object(Queue, {{queued, QueueName}, NextEntry}),
          ets:insert(Queue, {{running, QueueName}, NextEntry}),
          NextEntryKey = {NextEntry#qentry.pid, NextEntry#qentry.monref},
          ets:update_element(QueuePids, NextEntryKey, {#qpid.state, running}),
          make_running(NextEntry)
      end;
    [#qpid{q = QueueName, qref = QRef, state = queued}] ->
      % NOTE: if this one is queued, it means the queue was full, so don't
      % delete it (the queue) just yet
      Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
      ets:delete_object(Queue, {{queued, QueueName}, Entry}),
      ok
  end,
  ets:delete(QueuePids, {Pid, MonRef}),
  {noreply, State};

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State}.

%% }}}
%%----------------------------------------------------------
%% code change {{{

%% @private
%% @doc Handle code change.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

make_running(_Entry = #qentry{pid = Pid, qref = QRef}) ->
  Pid ! {go, QRef},
  ok.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
