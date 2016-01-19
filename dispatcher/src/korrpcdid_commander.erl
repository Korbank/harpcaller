%%%---------------------------------------------------------------------------
%%% @doc
%%%   Commander process for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_commander).

-behaviour(gen_server).

-export([process_command/2]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

-record(state, {}).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start example process.

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
  State = #state{},
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

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

handle_info({command, ReplyTo, ChannelID, Command} = _Message, State) ->
  spawn(?MODULE, process_command, [{ReplyTo, ChannelID}, Command]),
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

process_command(ReplyTo, [{<<"command">>, <<"stop">>}] = _Command) ->
  send_reply(ReplyTo, [{result, ok}, {pid, list_to_binary(os:getpid())}]),
  init:stop(),
  ok;

process_command(ReplyTo, [{_,_} | _] = Command) ->
  io:fwrite("got command ~p~n", [Command]),
  send_reply(ReplyTo, [{error, <<"unsupported command">>}]);

process_command(ReplyTo, [{}] = Command) ->
  io:fwrite("got command ~p~n", [Command]),
  send_reply(ReplyTo, [{error, <<"unsupported command">>}]);

process_command(ReplyTo, {_Cmd, _Opts} = Command) ->
  io:fwrite("got command ~p~n", [Command]),
  send_reply(ReplyTo, [{error, <<"unsupported command">>}]),
  ok.

send_reply({Pid, ChannelID} = _ReplyTo, Reply) ->
  Pid ! {result, ChannelID, Reply},
  ok.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
