%%%---------------------------------------------------------------------------
%%% @doc
%%%   Process that cleans up the old SDB files.
%%% @end
%%%---------------------------------------------------------------------------

-module(harp_sdb_cleanup).

-behaviour(gen_server).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(CLEANUP_INTERVAL, timer:seconds(60)).

-record(state, {
  timer :: reference()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start SDB cleaner.

start() ->
  gen_server:start(?MODULE, [], []).

%% @private
%% @doc Start SDB cleaner.

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init(_Args) ->
  harpcaller_log:set_context(sdb_cleanup, []),
  State = #state{
    timer = schedule_cleanup()
  },
  {ok, State}.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

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

handle_info(cleanup = _Message, State = #state{timer = Timer}) ->
  cancel_cleanup(Timer),
  NewTimer = schedule_cleanup(),
  remove_old_files(),
  NewState = State#state{timer = NewTimer},
  {noreply, NewState};

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

%% @doc Remove old files from SDB storage.

remove_old_files() ->
  case application:get_env(max_age) of
    {ok, MaxAgeHours} ->
      case harp_sdb:remove_older(MaxAgeHours * 3600) of
        {0, 0} ->
          ok;
        {0, ErrorCount} ->
          harpcaller_log:warn("problems during pruning old files",
                              [{errors, ErrorCount}]);
        {Deleted, ErrorCount} ->
          harpcaller_log:info("old files pruned",
                              [{deleted, Deleted}, {errors, ErrorCount}])
      end,
      ok;
    undefined ->
      ok
  end.

%%%---------------------------------------------------------------------------

%% @doc Schedule the next SDB cleanup.

-spec schedule_cleanup() ->
  reference().

schedule_cleanup() ->
  erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).

%% @doc Cancel a scheduled SDB cleanup.

-spec cancel_cleanup(reference()) ->
  ok.

cancel_cleanup(Timer) ->
  erlang:cancel_timer(Timer),
  % flush any `cleanup' message that could have arrived
  receive
    cleanup -> ok
  after 0 -> ok
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
