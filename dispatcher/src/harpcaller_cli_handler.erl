%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative command handler for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_cli_handler).

-behaviour(gen_indira_cli).

%% gen_indira_cli callbacks
-export([parse_arguments/2]).
-export([handle_command/2, format_request/2, handle_reply/3]).

-export([help/1]).
-export([format_error/1]).

%%%---------------------------------------------------------------------------

-define(ADMIN_SOCKET_TYPE, indira_unix).

-record(cmd, {
  op :: start | stop | status | reload_config
        | list_jobs | {cancel_job, string() | undefined}
        | list_hosts | refresh_hosts
        | list_queues | {list_queue, harpcaller_call_queue:queue_name()}
        | {cancel_queue, harpcaller_call_queue:queue_name() | undefined}
        | dist_start | dist_stop,
  socket :: file:filename(),
  options :: [{atom(), term()}]
}).

%%%---------------------------------------------------------------------------
%%% gen_indira_cli callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parse_arguments() {{{

parse_arguments(Args, [DefAdminSocket, DefConfigFile] = _DefaultValues) ->
  EmptyCommand = #cmd{
    socket = DefAdminSocket,
    options = [{config, DefConfigFile}]
  },
  case indira_cli:folds(fun cli_opt/2, EmptyCommand, Args) of
    {ok, Command = #cmd{op = start}} ->
      {ok, start, Command};
    {ok, Command = #cmd{op = stop}} ->
      {ok, stop, Command};
    {ok, Command = #cmd{op = status}} ->
      {ok, status, Command};

    {ok, _Command = #cmd{op = {cancel_job, undefined} }} ->
      {error, undefined_job};
    {ok, _Command = #cmd{op = {cancel_queue, undefined} }} ->
      {error, undefined_queue};

    {ok, _Command = #cmd{op = undefined}} ->
      help;

    {ok, Command = #cmd{op = Op, socket = Socket}} ->
      {send, {indira_unix, Socket}, Op, Command};

    {error, {help, _Arg}} ->
      help;

    {error, Reason} ->
      {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------
%% handle_command() {{{

handle_command(start = _Op,
               _Command = #cmd{socket = Socket, options = Options}) ->
  ConfigFile = proplists:get_value(config, Options),
  case load_config_file(ConfigFile) of
    {ok, Config} ->
      case setup_applications(Config, Options) of
        {ok, IndiraOptions} ->
          indira_app:daemonize(harpcaller, [
            {listen, [{indira_unix, Socket}]},
            {command, {harpcaller_command_handler, []}} |
            IndiraOptions
          ]);
        {error, Reason} ->
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end;

handle_command(stop = Op,
               Command = #cmd{socket = Socket, options = Options}) ->
  {ok, Request} = format_request(Op, Command),
  Timeout = proplists:get_value(timeout, Options, infinity),
  SendOpts = [{timeout, Timeout}],
  case indira_cli:send_one_command(indira_unix, Socket, Request, SendOpts) of
    {ok, Reply} ->
      handle_reply(Reply, Op, Command);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = harpcaller_command_handler:hardcoded_reply(ok),
      handle_reply(Reply, Op, Command);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = harpcaller_command_handler:hardcoded_reply(ok),
      handle_reply(Reply, Op, Command);
    {error, closed} ->
      % in the unlikely case of Erlang VM shutting down before allowing reply
      % to pass through
      Reply = harpcaller_command_handler:hardcoded_reply(ok),
      handle_reply(Reply, Op, Command);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end;

handle_command(status = Op,
               Command = #cmd{socket = Socket, options = Options}) ->
  {ok, Request} = format_request(Op, Command),
  Timeout = proplists:get_value(timeout, Options, infinity),
  SendOpts = case proplists:get_bool(wait, Options) of
    true  = Wait -> [{timeout, Timeout}, wait];
    false = Wait -> [{timeout, Timeout}]
  end,
  case indira_cli:send_one_command(indira_unix, Socket, Request, SendOpts) of
    {ok, Reply} ->
      handle_reply(Reply, Op, Command);
    {error, timeout} when Wait ->
      % FIXME: can be either timeout on connect or timeout on receiving a reply
      Reply = harpcaller_command_handler:hardcoded_reply(status_stopped),
      handle_reply(Reply, Op, Command);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = harpcaller_command_handler:hardcoded_reply(status_stopped),
      handle_reply(Reply, Op, Command);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = harpcaller_command_handler:hardcoded_reply(status_stopped),
      handle_reply(Reply, Op, Command);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end.

%% }}}
%%----------------------------------------------------------
%% format_request() + handle_reply() {{{

format_request(status = _Op, _Command = #cmd{options = Options}) ->
  Request = case proplists:get_bool(wait, Options) of
    true  -> harpcaller_command_handler:format_request(status_wait);
    false -> harpcaller_command_handler:format_request(status)
  end,
  {ok, Request};
format_request(Op, _Command) ->
  Request = harpcaller_command_handler:format_request(Op),
  {ok, Request}.

handle_reply(Reply, stop = Op, _Command = #cmd{options = Options}) ->
  PrintPid = proplists:get_bool(print_pid, Options),
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, Pid} when PrintPid -> io:fwrite("~s~n", [Pid]), ok;
    {ok, _Pid} when not PrintPid -> ok;
    ok -> ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, status = Op, _Command) ->
  % `status' and `status_wait' have the same `Op' and replies
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, <<"running">> = _Status} ->
      io:fwrite("harpcallerd is running~n"),
      ok;
    {ok, <<"stopped">> = _Status} ->
      io:fwrite("harpcallerd is stopped~n"),
      {error, 1};
    % for future changes in status detection
    {ok, Status} ->
      {error, {unknown_status, Status}}
  end;

handle_reply(Reply, list_jobs = Op, _Command) ->
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, Jobs} -> lists:foreach(fun print_json/1, Jobs), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, list_hosts = Op, _Command) ->
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, Hosts} -> lists:foreach(fun print_json/1, Hosts), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, list_queues = Op, _Command) ->
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, Queues} -> lists:foreach(fun print_json/1, Queues), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, {list_queue, _} = Op, _Command) ->
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    {ok, Jobs} -> lists:foreach(fun print_json/1, Jobs), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, Op, _Command) ->
  case harpcaller_command_handler:parse_reply(Reply, Op) of
    ok -> ok;
    {error, Reason} -> {error, Reason}
  end.

print_json(Struct) ->
  {ok, JSON} = indira_json:encode(Struct),
  io:put_chars([JSON, $\n]).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% setting up applications
%%%---------------------------------------------------------------------------

-spec setup_applications([{binary(), term()}], [{atom(), term()}]) ->
  {ok, IndiraOptions :: [{atom(), term()}]} | {error, term()}.

setup_applications(Config, Options) ->
  % TODO: add support for `erlang.error_logger_handlers' option back (maybe
  % better this time)
  case setup_harpcaller(Config) of
    ok -> indira_options(Config, Options);
    {error, Reason} -> {error, Reason}
  end.

%%----------------------------------------------------------
%% setup HarpCaller and Indira {{{

-spec setup_harpcaller([{binary(), term()}]) ->
  ok | {error, {invalid_option_format, binary()} | no_listen_addresses}.

setup_harpcaller(Config) ->
  SetSpecs = [
    {<<"listen">>,          {harpcaller, listen}},
    {<<"stream_directory">>,{harpcaller, stream_directory}},
    {<<"default_timeout">>, {harpcaller, default_timeout}},
    {<<"max_exec_time">>,   {harpcaller, max_exec_time}},
    {<<"host_db_script">>,  {harpcaller, host_db_script}},
    {<<"ca_file">>,         {harpcaller, ca_file}},
    {<<"known_certs_file">>,{harpcaller, known_certs_file}},
    {<<"host_db">>,         {harpcaller, host_db}},
    {<<"host_db_refresh">>, {harpcaller, host_db_refresh}},
    {<<"log_handlers">>,    {harpcaller, log_handlers}}
  ],
  case indira_app:set_env(fun config_opt/3, Config, SetSpecs) of
    ok ->
      ok;
    {error, {Key, _EnvKey, invalid_option_format}} ->
      {error, {invalid_option_format, Key}};
    {error, {_Key, _EnvKey, no_listen_addresses}} ->
      {error, no_listen_addresses}
  end.

-spec indira_options([{binary(), term()}], [{atom(), term()}]) ->
  {ok, [{atom(), term()}]} | {error, term()}.

indira_options(Config, Options) ->
  % TODO: precise pinpointing what option was invalid
  ErlangConfig = proplists:get_value(<<"erlang">>, Config, []),
  try
    % values from `Options' are guaranteed to be of proper format
    PidFile = proplists:get_value(pidfile, Options),
    NodeName = proplists:get_value(<<"node_name">>, ErlangConfig),
    true = (NodeName == undefined orelse is_binary(NodeName)),
    NameType = proplists:get_value(<<"name_type">>, ErlangConfig),
    true = (NameType == undefined orelse
            NameType == <<"longnames">> orelse NameType == <<"shortnames">>),
    Cookie = case proplists:get_value(<<"cookie_file">>, ErlangConfig) of
      CookieFile when is_binary(CookieFile) -> {file, CookieFile};
      undefined -> none
    end,
    NetStart = proplists:get_value(<<"distributed_immediate">>, ErlangConfig, false),
    true = is_boolean(NetStart),
    AdditionalOptions = case proplists:get_bool(debug, Options) of
      true -> [{start_before, sasl}];
      false -> []
    end,
    IndiraOptions = [
      {pidfile, PidFile},
      {node_name, make_atom(NodeName)},
      {name_type, make_atom(NameType)},
      {cookie, Cookie},
      {net_start, NetStart} |
      AdditionalOptions
    ],
    {ok, IndiraOptions}
  catch
    error:_ ->
      {error, invalid_option_format}
  end.

%% }}}
%%----------------------------------------------------------
%% check options from config file {{{

config_opt(_Key, _EnvKey, undefined = _Value) ->
  ignore;

config_opt(<<"listen">> = _Key, _EnvKey, Specs) ->
  try [parse_listen_spec(S) || S <- Specs] of
    [] -> {error, no_listen_addresses};
    Addresses -> {ok, Addresses}
  catch
    error:_ -> {error, invalid_option_format}
  end;

config_opt(<<"stream_directory">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_opt(<<"default_timeout">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_opt(<<"max_exec_time">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_opt(<<"ca_file">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_opt(<<"known_certs_file">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_opt(<<"host_db_script">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_opt(<<"host_db">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_opt(<<"host_db_refresh">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_opt(<<"log_handlers">> = _Key, _EnvKey, Handlers) ->
  try
    {ok, [{binary_to_atom(H, utf8), []} || H <- Handlers]}
  catch
    error:_ -> {error, invalid_option_format}
  end;

config_opt(_Key, _EnvKey, _Value) ->
  {error, invalid_option_format}.

%% }}}
%%----------------------------------------------------------
%% smaller helpers {{{

parse_listen_spec(Spec) when is_binary(Spec) ->
  % die when the listen specification doesn't match what we expect
  case binary:split(Spec, <<":">>) of
    [<<"*">>, PortBin] -> {any, make_int(PortBin)};
    [AddrBin, PortBin] -> {binary_to_list(AddrBin), make_int(PortBin)}
  end.

make_atom(String) when is_binary(String) ->
  binary_to_atom(String, utf8);
make_atom(String) when is_atom(String) ->
  String.

make_int(Num) when is_binary(Num) ->
  list_to_integer(binary_to_list(Num)).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% config file loading
%%%---------------------------------------------------------------------------

-spec load_config_file(file:filename()) ->
    {ok, Config :: [{binary(), term()}]}
  | {error, {config_reading_error | config_parse_error, term()}}.

load_config_file(ConfigFile) ->
  case file:read_file(ConfigFile) of
    {ok, ConfigContent} ->
      case etoml:parse(ConfigContent) of
        {ok, Config} ->
          {ok, Config};
        {error, Reason} ->
          {error, {config_parse_error, Reason}}
      end;
    {error, Reason} ->
      {error, {config_reading_error, Reason}}
  end.

%%%---------------------------------------------------------------------------
%%% command line parsing
%%%---------------------------------------------------------------------------

help(Script) ->
  _HelpMessage = [
    "HarpCaller daemon.\n",
    "\n",
    "Daemon control:\n",
    "  ", Script, " [--socket=...] start [--debug] [--config=...] [--pidfile=...]\n",
    "  ", Script, " [--socket=...] status [--wait [--timeout=...]]\n",
    "  ", Script, " [--socket=...] stop [--timeout=...] [--print-pid]\n",
    "  ", Script, " [--socket=...] reload-config\n",
    "Jobs:\n",
    "  ", Script, " [--socket=...] list\n",
    "  ", Script, " [--socket=...] cancel <job-id>\n",
    "Hosts registry:\n",
    "  ", Script, " [--socket=...] hosts-list\n",
    "  ", Script, " [--socket=...] hosts-refresh\n",
    "Job queues:\n",
    "  ", Script, " [--socket=...] queue-list\n",
    "  ", Script, " [--socket=...] queue-list <queue-name>\n",
    "  ", Script, " [--socket=...] queue-cancel <queue-name>\n",
    "Distributed Erlang support:\n",
    "  ", Script, " [--socket=...] dist-erl-start\n",
    "  ", Script, " [--socket=...] dist-erl-stop\n"
  ].

-spec cli_opt(string() | [string()], #cmd{}) ->
  #cmd{} | {error, help | invalid_option | invalid_command | excessive_argument |
                          invalid_timeout | invalid_queue_name}.

cli_opt("--help", _Cmd) ->
  {error, help};
cli_opt("-h", _Cmd) ->
  {error, help};

cli_opt("--debug", Cmd = #cmd{options = Options}) ->
  _NewCmd = Cmd#cmd{options = [{debug, true} | Options]};

cli_opt("--wait", Cmd = #cmd{options = Options}) ->
  _NewCmd = Cmd#cmd{options = [{wait, true} | Options]};

cli_opt("--print-pid", Cmd = #cmd{options = Options}) ->
  _NewCmd = Cmd#cmd{options = [{print_pid, true} | Options]};

cli_opt("--socket=" ++ Socket, Cmd) ->
  cli_opt(["--socket", Socket], Cmd);
cli_opt("--socket", _Cmd) ->
  {need, 1};
cli_opt(["--socket", Socket], Cmd) ->
  _NewCmd = Cmd#cmd{socket = Socket};

cli_opt("--config=" ++ Path, Cmd) ->
  cli_opt(["--config", Path], Cmd);
cli_opt("--config", _Cmd) ->
  {need, 1};
cli_opt(["--config", Path], Cmd = #cmd{options = Options}) ->
  _NewCmd = Cmd#cmd{options = [{config, Path} | Options]};

cli_opt("--pidfile=" ++ Path, Cmd) ->
  cli_opt(["--pidfile", Path], Cmd);
cli_opt("--pidfile", _Cmd) ->
  {need, 1};
cli_opt(["--pidfile", Path], Cmd = #cmd{options = Options}) ->
  _NewCmd = Cmd#cmd{options = [{pidfile, Path} | Options]};

cli_opt("--timeout=" ++ Seconds, Cmd) ->
  cli_opt(["--timeout", Seconds], Cmd);
cli_opt("--timeout", _Cmd) ->
  {need, 1};
cli_opt(["--timeout", Seconds], Cmd = #cmd{options = Options}) ->
  try
    Timeout = list_to_integer(Seconds),
    true = (Timeout > 0),
    _NewCmd = Cmd#cmd{options = [{timeout, 1000 * Timeout} | Options]}
  catch
    error:_ ->
      {error, invalid_timeout}
  end;

cli_opt("-" ++ _, _Cmd) ->
  {error, invalid_option};

cli_opt("start", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = start};

cli_opt("stop", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = stop};

cli_opt("status", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = status};

cli_opt("reload-config", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = reload_config};

cli_opt("list", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = list_jobs};

cli_opt("cancel", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = {cancel_job, undefined}};
cli_opt(JobID, Cmd = #cmd{op = {cancel_job, undefined}}) ->
  _NewCmd = Cmd#cmd{op = {cancel_job, JobID}};

cli_opt("hosts-list", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = list_hosts};

cli_opt("hosts-refresh", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = refresh_hosts};

cli_opt("queue-list", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = list_queues};
cli_opt(Queue, Cmd = #cmd{op = list_queues}) ->
  case indira_json:decode(Queue) of
    {ok, Struct} -> _NewCmd = Cmd#cmd{op = {list_queue, Struct}};
    {error, _} -> {error, invalid_queue_name}
  end;

cli_opt("queue-cancel", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = {cancel_queue, undefined}};
cli_opt(Queue, Cmd = #cmd{op = {cancel_queue, undefined}}) ->
  case indira_json:decode(Queue) of
    {ok, Struct} -> _NewCmd = Cmd#cmd{op = {cancel_queue, Struct}};
    {error, _} -> {error, invalid_queue_name}
  end;

cli_opt("dist-erl-start", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = dist_start};

cli_opt("dist-erl-stop", Cmd = #cmd{op = undefined}) ->
  _NewCmd = Cmd#cmd{op = dist_stop};

cli_opt(_Arg, _Cmd = #cmd{op = undefined}) ->
  {error, invalid_command};

cli_opt(_Arg, _Cmd) ->
  {error, excessive_argument}.

%%%---------------------------------------------------------------------------

-spec format_error(term()) ->
  iolist() | binary().

%% `gen_indira_cli' callback returns invalid value
format_error({bad_return_value, Value}) ->
  io_lib:format("invalid return value from callback: ~1024p", [Value]);

%% parse_arguments()
format_error({arguments, {invalid_option, Arg}}) ->
  ["invalid option: ", Arg];
format_error({arguments, {invalid_command, Arg}}) ->
  ["invalid command: ", Arg];
format_error({arguments, {excessive_argument, Arg}}) ->
  ["excessive argument: ", Arg];
format_error({arguments, {invalid_timeout, _Arg}}) ->
  "invalid timeout";
format_error({arguments, {invalid_queue_name, _Arg}}) ->
  "invalid queue name";

%% "send request-receive reply-handle reply" operation mode
format_error({send, bad_request_format}) ->
  "invalid request format (programmer's error)";
format_error({send, bad_reply_format}) ->
  "invalid reply format (daemon's error)";
format_error({send, Reason}) ->
  io_lib:format("request sending error: ~1024p", [Reason]);

%% TOML reading (file:read_file())
format_error({config_reading_error, Reason}) ->
  ["config reading error: ", file:format_error(Reason)];

%% TOML parsing
format_error({config_parse_error, {invalid_key, Line}}) ->
  io_lib:format("line ~B: invalid key name", [Line]);
format_error({config_parse_error, {invalid_group, Line}}) ->
  io_lib:format("line ~B: invalid group name", [Line]);
format_error({config_parse_error, {invalid_date, Line}}) ->
  io_lib:format("line ~B: invalid date format", [Line]);
format_error({config_parse_error, {invalid_number, Line}}) ->
  io_lib:format("line ~B: invalid number value or forgotten quotes", [Line]);
format_error({config_parse_error, {invalid_array, Line}}) ->
  io_lib:format("line ~B: invalid array format", [Line]);
format_error({config_parse_error, {invalid_string, Line}}) ->
  io_lib:format("line ~B: invalid string format", [Line]);
format_error({config_parse_error, {undefined_value, Line}}) ->
  io_lib:format("line ~B: value not provided", [Line]);
format_error({config_parse_error, {duplicated_key, Key}}) ->
  io_lib:format("duplicated key: ~s", [Key]);

%% setup_harpcaller()
format_error({invalid_option_format, Option}) ->
  ["invalid config option: ", Option];
format_error(no_listen_addresses) ->
  "no listen addresses in configuration";
%% indira_options()
format_error(invalid_option_format) ->
  "invalid config option in [erlang] section";

%% options to indira_app:daemonize() are guaranteed to be of proper format

format_error({unknown_status, Status}) ->
  ["unknown status: ", Status];

%% `harpcaller_command_handler:parse_reply()'
format_error(Message) when is_binary(Message) ->
  Message;

%% unrecognized errors
format_error(Reason) ->
  io_lib:format("unrecognized error: ~1024p", [Reason]).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
