%%%---------------------------------------------------------------------------
%%% @doc
%%%   Event log collector process and logging functions.
%%%
%%%   Process conforms to {@link gen_event} interface and loads all the event
%%%   handlers defined in `korrpcdid' application's environment `log_handlers'
%%%   (a list of tuples {@type @{atom(), term()@}}).
%%%
%%%   The events send with these functions have following structure:
%%%   {@type @{log, pid(), info | warning | error, event_type(),
%%%     event_info()@}}.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_log).

%% public interface
-export([info/2, warn/2, err/2]).
-export([info/3, warn/3, err/3]).

%% supervision tree API
-export([start/0, start_link/0]).

%%%---------------------------------------------------------------------------

-type event_info() :: [{atom(), korrpc_json:jhash() | {term, term()} | {str, string()}}].

-type event_type() :: atom().

-type event_message() :: string() | binary().

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.

-spec info(event_type(), event_info()) ->
  ok.

info(EventType, EventInfo) ->
  event(info, EventType, EventInfo).

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.

-spec info(event_type(), event_message(), event_info()) ->
  ok.

info(EventType, Message, EventInfo) ->
  info(EventType, [{message, message(Message)} | EventInfo]).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of KorRPC dispatcher.

-spec warn(event_type(), event_info()) ->
  ok.

warn(EventType, EventInfo) ->
  event(warning, EventType, EventInfo).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of KorRPC dispatcher.

-spec warn(event_type(), event_message(), event_info()) ->
  ok.

warn(EventType, Message, EventInfo) ->
  warn(EventType, [{message, message(Message)} | EventInfo]).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).

-spec err(event_type(), event_info()) ->
  ok.

err(EventType, EventInfo) ->
  event(error, EventType, EventInfo).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).

-spec err(event_type(), event_message(), event_info()) ->
  ok.

err(EventType, Message, EventInfo) ->
  err(EventType, [{message, message(Message)} | EventInfo]).

%%----------------------------------------------------------
%% public interface helpers
%%----------------------------------------------------------

%% @doc Send an event to the logger.

-spec event(info | warning | error, event_type(), event_info()) ->
  ok.

event(Level, Type, Info) ->
  gen_event:notify(?MODULE, {log, self(), Level, Type, Info}).

%% @doc Ensure that event message is a binary.

-spec message(event_message()) ->
  binary().

message(Message) when is_list(Message) ->
  list_to_binary(Message);
message(Message) when is_binary(Message) ->
  Message.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start() ->
  case gen_event:start({local, ?MODULE}) of
    {ok, Pid} ->
      case add_handlers(Pid, get_handlers()) of
        ok ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @private
%% @doc Start example process.

start_link() ->
  case gen_event:start_link({local, ?MODULE}) of
    {ok, Pid} ->
      case add_handlers(Pid, get_handlers()) of
        ok ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Get handlers defined in application environment.

-spec get_handlers() ->
  [{atom(), term()}].

get_handlers() ->
  case application:get_env(korrpcdid, log_handlers) of
    {ok, LogHandlers} -> LogHandlers;
    undefined -> []
  end.

%% @doc Add event handlers to gen_event.

-spec add_handlers(pid(), [{atom(), term()}]) ->
  ok | {error, term()}.

add_handlers(_Pid, [] = _Handlers) ->
  ok;
add_handlers(Pid, [{Mod, Args} | Rest] = _Handlers) ->
  case gen_event:add_handler(Pid, Mod, Args) of
    ok -> add_handlers(Pid, Rest);
    {error, Reason} -> {error, {Mod, Reason}};
    {'EXIT', Reason} -> {error, {exit, Mod, Reason}}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
