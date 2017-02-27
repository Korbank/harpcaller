%%%---------------------------------------------------------------------------
%%% @doc
%%%   Connection acceptor process.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_tcp_listener).

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
  harpcaller_log:set_context(connection, [
    {address, {str, format_address(Addr)}},
    {port, Port}
  ]),
  case tcp_bind_addr_opts(Addr) of
    {ok, Opts} ->
      harpcaller_log:info("listening on TCP socket"),
      case gen_tcp:listen(Port, [{active, false}, {packet, line}, binary,
                                  {reuseaddr, true} | Opts]) of
        {ok, Socket} ->
          State = #state{socket = Socket},
          {ok, State, 0};
        {error, Reason} ->
          harpcaller_log:err("TCP listen error", [{error, {term, Reason}}]),
          {stop, Reason}
      end;
    {error, Reason} ->
      harpcaller_log:err("TCP listen address resolve error",
                         [{error, {term, Reason}}]),
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
handle_call(Request, From, State) ->
  harpcaller_log:unexpected_call(Request, From, ?MODULE),
  {reply, {error, unknown_call}, State, 0}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(Request, State) ->
  harpcaller_log:unexpected_cast(Request, ?MODULE),
  {noreply, State, 0}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message, State = #state{socket = Socket}) ->
  case gen_tcp:accept(Socket, ?ACCEPT_INTERVAL) of
    {ok, Client} ->
      harpcaller_tcp_worker:take_over(Client),
      {noreply, State, 0};
    {error, timeout} ->
      {noreply, State, 0};
    {error, Reason} ->
      harpcaller_log:err("accept error", [{error, {term, Reason}}]),
      {stop, Reason}
  end;

%% unknown messages
handle_info(Message, State) ->
  harpcaller_log:unexpected_info(Message, ?MODULE),
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

-spec format_address(harpcaller:address()) ->
  string().

format_address(Address) when is_list(Address) ->
  Address;
format_address(any = _Address) ->
  "*";
format_address(Address) when is_atom(Address) ->
  atom_to_list(Address);
format_address({A,B,C,D} = _Address) ->
  % TODO: IPv6
  OctetList = [
    integer_to_list(A),
    integer_to_list(B),
    integer_to_list(C),
    integer_to_list(D)
  ],
  string:join(OctetList, ".").

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
