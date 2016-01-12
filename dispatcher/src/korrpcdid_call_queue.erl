%%%---------------------------------------------------------------------------
%%% @doc
%%%   Call queue handler.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_call_queue).

-behaviour(gen_server).

%% public interface
-export([enqueue/2]).
-export([cancel/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

-export_type([queue_name/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-define(LOG_CAT, call_queue).

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
%%
%%   Function returns a queue reference `QRef'. When the time comes (the
%%   requested queue has less than `Concurrency' running processes), the
%%   calling process will get `{go, QRef}' message.
%%
%%   If the queue ever gets deleted ({@link cancel/1}), each enqueued process
%%   (either waiting for its turn or already running) will receive
%%   `{cancel, QRef}' message.

-spec enqueue(queue_name(), pos_integer()) ->
  reference().

enqueue(QueueName, Concurrency) when is_integer(Concurrency), Concurrency > 0 ->
  gen_server:call(?MODULE, {enqueue, self(), QueueName, Concurrency}).

%% @doc Delete a queue, cancelling everything in it.
%%
%%   <b>NOTE</b>: This function is more of an administrative one than
%%   something to lean your architecture on. It returns as soon as the tasks
%%   are sent notifications to should shut down and allows the queue to
%%   terminate in its normal way. If some task comes to the queue just after
%%   notifications were sent, the queue will not get deleted in effect.

-spec cancel(queue_name()) ->
  ok.

cancel(QueueName) ->
  gen_server:call(?MODULE, {cancel, QueueName}).

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

handle_call({enqueue, Pid, QueueName, Concurrency} = _Request, _From, State) ->
  QRef = make_ref(),
  MonRef = remember_process(Pid, QRef, QueueName, State),
  Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
  % create a queue if it doesn't exist already
  case create_queue(QueueName, Concurrency, State) of
    true -> korrpcdid_log:info(?LOG_CAT, "queue created",
                               [{name, QueueName}, {max_running, Concurrency}]);
    false -> ok
  end,
  case queue_status(QueueName, State) of
    #qopts{running = N, concurrency = C} when N < C ->
      % queue with spare room to run a task
      korrpcdid_log:info(?LOG_CAT, "queue has spare room, starting job",
                         [{pid, {term, Pid}}, {name, QueueName},
                          {running, N}, {max_running, C}]),
      make_running(Entry, QueueName, State);
    #qopts{running = N, concurrency = C} when N >= C ->
      % queue full of running tasks
      korrpcdid_log:info(?LOG_CAT, "queue maxed out, holding job",
                         [{pid, {term, Pid}}, {name, QueueName},
                          {max_running, C}]),
      add_queued(Entry, QueueName, State)
  end,
  {reply, QRef, State};

handle_call({cancel, QueueName} = _Request, _From, State) ->
  korrpcdid_log:info(?LOG_CAT, "cancelling queue", [{name, QueueName}]),
  [Pid ! {cancel, QRef} ||
    #qentry{pid = Pid, qref = QRef} <- list_queued(QueueName, State)],
  [Pid ! {cancel, QRef} ||
    #qentry{pid = Pid, qref = QRef} <- list_running(QueueName, State)],
  % XXX: deleting the queue will be done as `DOWN' messages arrive
  {reply, ok, State};

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

handle_info({'DOWN', MonRef, process, Pid, _Info} = _Message, State) ->
  case recall_process(Pid, MonRef, State) of
    none ->
      % it wasn't a process monitored because of queue
      ignore;
    {QRef, QueueName, running} ->
      Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
      RunningCount = delete_running(Entry, QueueName, State),
      QueuedTasks = list_queued(QueueName, State),
      case {QueuedTasks, RunningCount} of
        {[], _} when RunningCount > 0 ->
          % nothing left in queue, but there's still some processes running
          korrpcdid_log:info(?LOG_CAT, "running job stopped, nothing to run left",
                             [{pid, {term, Pid}}, {name, QueueName}]),
          ok;
        {[], 0} ->
          % nothing left in queue and this was the last running process
          korrpcdid_log:info(?LOG_CAT, "last running job stopped, queue empty",
                             [{pid, {term, Pid}}, {name, QueueName}]),
          delete_queue(QueueName, State);
        {[NextEntry = #qentry{pid = NextPid} | _], _} ->
          % still something in the queue; make it running
          korrpcdid_log:info(?LOG_CAT, "running job stopped, starting another",
                             [{pid, {term, Pid}}, {next_pid, {term, NextPid}},
                              {name, QueueName}]),
          make_running(NextEntry, QueueName, State)
      end;
    {QRef, QueueName, queued} ->
      % NOTE: if this one is queued, it means the queue was full, so don't
      % delete it (the queue) just yet
      Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
      korrpcdid_log:info(?LOG_CAT, "waiting job stopped",
                         [{pid, {term, Pid}}, {name, QueueName}]),
      delete_queued(Entry, QueueName, State),
      ok
  end,
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
%%% helpers for working with whole queues {{{

%% @doc Create a queue with specified concurrency level.
%%   This mainly records options for the queue with running counter starting
%%   at 0, as the queue's content is {@type #qentry@{@}} under (typically
%%   duplicated) key of queue name.

-spec create_queue(queue_name(), pos_integer(), #state{}) ->
  true | false.

create_queue(QueueName, Concurrency, _State = #state{qopts = QueueOpts}) ->
  ets:insert_new(QueueOpts, #qopts{
    name = QueueName,
    running = 0,
    concurrency = Concurrency
  }).

%% @doc Get status of the queue.
%%   Returns queue's options, which include recorded running counter.

-spec queue_status(queue_name(), #state{}) ->
  #qopts{}.

queue_status(QueueName, _State = #state{qopts = QueueOpts}) ->
  [Q] = ets:lookup(QueueOpts, QueueName),
  Q.

%% @doc Delete remains of the queue.
%%   Namely, the queue's options.

-spec delete_queue(queue_name(), #state{}) ->
  true.

delete_queue(QueueName, _State = #state{qopts = QueueOpts}) ->
  ets:delete(QueueOpts, QueueName).

%%% }}}
%%%---------------------------------------------------------------------------
%%% helpers for working with enqueued tasks {{{

%% @doc Add to a queue a task that will be waiting for execution.
%%
%%   Function <em>does not</em> update running counter in {@link
%%   queue_status/2. queue status} (because why should it?).

-spec add_queued(#qentry{}, queue_name(), #state{}) ->
  ok.

add_queued(Entry, QueueName, _State = #state{q = Queue}) ->
  ets:insert(Queue, {{queued, QueueName}, Entry}),
  ok.

%% @doc Delete from a queue a task that is still waiting for execution.
%%   The task has just terminated.

-spec delete_queued(#qentry{}, queue_name(), #state{}) ->
  ok.

delete_queued(Entry, QueueName, _State = #state{q = Queue}) ->
  ets:delete_object(Queue, {{queued, QueueName}, Entry}),
  ok.

%% @doc Delete from a queue a task that was running.
%%   The task has just terminated.
%%
%%   Function updates running counter in {@link queue_status/2. queue status}
%%   and returns its new value.

-spec delete_running(#qentry{}, queue_name(), #state{}) ->
  non_neg_integer().

delete_running(Entry, QueueName,
               _State = #state{q = Queue, qopts = QueueOpts}) ->
  ets:delete_object(Queue, {{running, QueueName}, Entry}),
  _Count = ets:update_counter(QueueOpts, QueueName, {#qopts.running, -1}).

%% @doc List tasks waiting for execution in specified queue.
%%   Tasks are returned in order of their appearance, as {@link ets}
%%   guarantees for tables of type `bag' (see {@link ets:lookup/2}).

-spec list_queued(queue_name(), #state{}) ->
  [#qentry{}].

list_queued(QueueName, _State = #state{q = Queue}) ->
  % strip the key from result tuples
  [E || {{queued, _}, E} <- ets:lookup(Queue, {queued, QueueName})].

%% @doc List tasks already running in specified queue.
%%   Tasks are returned in order of their appearance, as {@link ets}
%%   guarantees for tables of type `bag' (see {@link ets:lookup/2}).

-spec list_running(queue_name(), #state{}) ->
  [#qentry{}].

list_running(QueueName, _State = #state{q = Queue}) ->
  % strip the key from result tuples
  [E || {{running, _}, E} <- ets:lookup(Queue, {running, QueueName})].

%% @doc Mark the task as running and tell it to start.
%%
%%   The task might or might not be added earlier as waiting for execution,
%%   both cases are handled.
%%
%%   The task (process) is sent a message `{go, Ref}', where `Ref' is the
%%   reference returned by {@link enqueue/2}.
%%
%%   Function updates running counter in {@link queue_status/2. queue status}.

-spec make_running(#qentry{}, queue_name(), #state{}) ->
  ok.

make_running(Entry = #qentry{pid = Pid, monref = MonRef, qref = QRef},
             QueueName, State = #state{q = Queue, qopts = QueueOpts}) ->
  delete_queued(Entry, QueueName, State), % if there was any
  update_process_state(Pid, MonRef, running, State),
  ets:update_counter(QueueOpts, QueueName, {#qopts.running, 1}),
  ets:insert(Queue, {{running, QueueName}, Entry}),
  Pid ! {go, QRef},
  ok.

%%% }}}
%%%---------------------------------------------------------------------------
%%% helpers for remembering/monitoring enqueued tasks {{{

%% @doc Monitor task, remembering some details about it.
%%   Function returns reference as returned by `monitor/2' (i.e., expect
%%   a message ``{'DOWN',...}'' with this reference).
%%
%%   `QRef' is a queue reference that will be returned to the enqueued
%%   process (see {@link enqueue/2}).
%%
%%   The process will be remembered with running state as `queued'. Use
%%   {@link update_process_state/4} to change that.
%%
%%   This function must be called prior to a {@link make_running/3} call.
%%   Simply calling it as a first thing on every arriving enqueueing request
%%   should be enough.

-spec remember_process(pid(), reference(), queue_name(), #state{}) ->
  reference().

remember_process(Pid, QRef, QueueName,
                 _State = #state{qpids = QueuePids}) ->
  MonRef = monitor(process, Pid),
  ets:insert(QueuePids, #qpid{
    key = {Pid, MonRef},
    q = QueueName,
    qref = QRef,
    state = queued % will be updated by `make_running()'
  }),
  MonRef.

%% @doc Update remembered running state about monitored process.
%%   This function is mainly used when a process starts its execution.

-spec update_process_state(pid(), reference(), running | queued, #state{}) ->
  ok.

update_process_state(Pid, MonRef, NewProcState,
                     _State = #state{qpids = QueuePids}) ->
  ets:update_element(QueuePids, {Pid, MonRef}, {#qpid.state, NewProcState}),
  ok.

%% @doc Recall the task details about a (monitored) process that has
%%   terminated. The details include queue reference returned to the process,
%%   name of its queue and its running state (either `running' or `queued').
%%
%%   If the process was not monitored using {@link remember_process/4}, `none'
%%   is returned.

-spec recall_process(pid(), reference(), #state{}) ->
  {QRef :: reference(), queue_name(), running | queued} | none.

recall_process(Pid, MonRef, _State = #state{qpids = QueuePids}) ->
  case ets:lookup(QueuePids, {Pid, MonRef}) of
    [] ->
      none;
    [#qpid{qref = QRef, q = QueueName, state = running}] ->
      ets:delete(QueuePids, {Pid, MonRef}), % it will no longer be necessary
      {QRef, QueueName, running};
    [#qpid{qref = QRef, q = QueueName, state = queued}] ->
      ets:delete(QueuePids, {Pid, MonRef}), % it will no longer be necessary
      {QRef, QueueName, queued}
  end.

%%% }}}
%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
