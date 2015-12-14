%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Connection acceptor process.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_tcp_listener).

-behaviour(gen_server).

%% supervision tree API
-export([start/1, start_link/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% {{{

-define(ACCEPT_INTERVAL, 100).

-record(state, {socket}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start acceptor process.

start({Addr, Port} = _ListenSpec) ->
  gen_server:start(?MODULE, [Addr, Port], []).

%% @private
%% @doc Start acceptor process.

start_link({Addr, Port} = _ListenSpec) ->
  gen_server:start_link(?MODULE, [Addr, Port], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([Addr, Port] = _Args) ->
  case tcp_bind_addr_opts(Addr) of
    {ok, Opts} ->
      case gen_tcp:listen(Port, [{active, false}, {packet, line}, binary,
                                  {reuseaddr, true} | Opts]) of
        {ok, Socket} ->
          State = #state{socket = Socket},
          {ok, State, 0};
        {error, Reason} ->
          {stop, Reason}
      end;
    {error, Reason} ->
      {stop, Reason}
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{socket = Socket}) ->
  gen_tcp:close(Socket),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State, 0}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State, 0}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message, State = #state{socket = Socket}) ->
  case gen_tcp:accept(Socket, ?ACCEPT_INTERVAL) of
    {ok, Client} ->
      {ok, Pid} = korrpcdid_tcp_worker_sup:spawn_worker(Client),
      case gen_tcp:controlling_process(Client, Pid) of
        ok -> ok;
        {error, _Reason} -> gen_tcp:close(Client)
      end,
      {noreply, State, 0};
    {error, timeout} ->
      {noreply, State, 0};
    {error, Reason} ->
      {stop, Reason}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State, 0}.

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

tcp_bind_addr_opts(any = _Addr) ->
  {ok, []};
tcp_bind_addr_opts(Addr) when is_tuple(Addr) ->
  {ok, [{ip, Addr}]};
tcp_bind_addr_opts(Addr) when is_list(Addr); is_atom(Addr) ->
  case inet:getaddr(Addr, inet) of
    {ok, IPAddr} -> {ok, [{ip, IPAddr}]};
    {error, Reason} -> {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
