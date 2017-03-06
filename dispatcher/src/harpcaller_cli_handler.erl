%%%---------------------------------------------------------------------------
%%% @doc
%%%   Module that handles command line operations.
%%%   This includes parsing provided arguments and either starting the daemon
%%%   or sending it various administrative commands.
%%%
%%% @see harpcaller_command_handler
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_cli_handler).

-behaviour(gen_indira_cli).

%% interface for daemonizing script
-export([format_error/1]).
-export([help/1]).

-export([load_app_config/2]).

%% gen_indira_cli callbacks
-export([parse_arguments/2]).
-export([handle_command/2, format_request/2, handle_reply/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(ADMIN_COMMAND_MODULE, harpcaller_command_handler).
% XXX: `status' and `stop' commands are bound to few specific errors this
% module returns; this can't be easily moved to a config/option
-define(ADMIN_SOCKET_TYPE, indira_unix).

-type config_value() :: binary() | number() | boolean().
-type config_key() :: binary().
-type config() :: [{config_key(), config_value() | config()}].

-record(opts, {
  op :: start | status | stop | reload_config
      | list_jobs | {cancel_job, string() | undefined}
      | {job_info, string() | undefined}
      | list_hosts | refresh_hosts
      | list_queues | {list_queue, harpcaller_call_queue:queue_name()}
      | {cancel_queue, harpcaller_call_queue:queue_name() | undefined}
      | dist_start | dist_stop
      | prune_jobs | reopen_logs,
  admin_socket :: file:filename(),
  options :: [{atom(), term()}]
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% gen_indira_cli callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parse_arguments() {{{

%% @private
%% @doc Parse command line arguments and decode opeartion from them.

parse_arguments(Args, [DefAdminSocket, DefConfig] = _Defaults) ->
  EmptyOptions = #opts{
    admin_socket = DefAdminSocket,
    options = [
      {config, DefConfig},
      {age, 30} % default age for pruning stream logs
    ]
  },
  case indira_cli:folds(fun cli_opt/2, EmptyOptions, Args) of
    {ok, Options = #opts{op = start }} -> {ok, start,  Options};
    {ok, Options = #opts{op = status}} -> {ok, status, Options};
    {ok, Options = #opts{op = stop  }} -> {ok, stop,   Options};

    {ok, _Options = #opts{op = {cancel_job, undefined} }} ->
      {error, undefined_job};
    {ok, _Options = #opts{op = {job_info, undefined} }} ->
      {error, undefined_job};
    {ok, _Options = #opts{op = {cancel_queue, undefined} }} ->
      {error, undefined_queue};

    {ok, _Options = #opts{op = undefined}} ->
      help;

    {ok, Options = #opts{op = Command, admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, Command, Options};

    {error, {help, _Arg}} ->
      help;

    {error, {Reason, Arg}} ->
      {error, {Reason, Arg}}
  end.

%% }}}
%%----------------------------------------------------------
%% handle_command() {{{

%% @private
%% @doc Execute commands more complex than "request -> reply -> print".

handle_command(start = _Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  ConfigFile = proplists:get_value(config, CLIOpts),
  case read_config_file(ConfigFile) of
    {ok, Config} ->
      indira_app:set_option(harpcaller, configure,
                            {?MODULE, load_app_config, [ConfigFile, Options]}),
      case setup_applications(Config, Options) of
        {ok, IndiraOptions} ->
          indira_app:daemonize(harpcaller, [
            {listen, [{?ADMIN_SOCKET_TYPE, Socket}]},
            {command, {?ADMIN_COMMAND_MODULE, []}} |
            IndiraOptions
          ]);
        {error, Reason} ->
          {error, {configure, Reason}}
      end;
    {error, Reason} ->
      % Reason :: {config_format | config_read, term()}
      {error, Reason}
  end;

handle_command(status = Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  Timeout = proplists:get_value(timeout, CLIOpts, infinity),
  Opts = case proplists:get_bool(wait, CLIOpts) of
    true  = Wait -> [{timeout, Timeout}, retry];
    false = Wait -> [{timeout, Timeout}]
  end,
  {ok, Request} = format_request(Command, Options),
  case indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, timeout} when Wait ->
      % FIXME: can be either timeout on connect or timeout on receiving a reply
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end;

handle_command(stop = Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  Timeout = proplists:get_value(timeout, CLIOpts, infinity),
  Opts = [{timeout, Timeout}],
  {ok, Request} = format_request(Command, Options),
  case indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, closed} ->
      % AF_UNIX socket exists, but nothing listens there (stale socket)
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end.

%% }}}
%%----------------------------------------------------------
%% format_request() + handle_reply() {{{

%% @private
%% @doc Format a request to send to daemon.

format_request(status = _Command, _Options = #opts{options = CLIOpts}) ->
  Request = case proplists:get_bool(wait, CLIOpts) of
    true  -> ?ADMIN_COMMAND_MODULE:format_request(status_wait);
    false -> ?ADMIN_COMMAND_MODULE:format_request(status)
  end,
  {ok, Request};
format_request(prune_jobs = _Command, _Options = #opts{options = CLIOpts}) ->
  Age = proplists:get_value(age, CLIOpts),
  Request = ?ADMIN_COMMAND_MODULE:format_request({prune_jobs, Age}),
  {ok, Request};
format_request(Command, _Options) ->
  Request = ?ADMIN_COMMAND_MODULE:format_request(Command),
  {ok, Request}.

%% @private
%% @doc Handle a reply to a command sent to daemon.

handle_reply(Reply, status = Command, _Options) ->
  % `status' and `status_wait' have the same `Command' and replies
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    running ->
      println("harpcallerd is running"),
      ok;
    stopped ->
      println("harpcallerd is stopped"),
      {error, 1};
    % for future changes in status detection
    Status ->
      {error, {unknown_status, Status}}
  end;

handle_reply(Reply, stop = Command, _Options = #opts{options = CLIOpts}) ->
  PrintPid = proplists:get_bool(print_pid, CLIOpts),
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Pid} when PrintPid -> println(Pid), ok;
    {ok, _Pid} when not PrintPid -> ok;
    ok -> ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, reload_config = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    ok -> ok;
    {error, Errors} ->
      printerr("reload errors:"),
      lists:foreach(
        fun({Part, Error}) -> printerr(["  ", Part, ": ", Error]) end,
        Errors
      ),
      {error, 1}
  end;

handle_reply(Reply, list_jobs = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Jobs} -> lists:foreach(fun print_json/1, Jobs), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, {job_info, _} = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, JobInfo} -> print_json(JobInfo), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, list_hosts = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Hosts} -> lists:foreach(fun print_json/1, Hosts), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, list_queues = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Queues} -> lists:foreach(fun print_json/1, Queues), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, {list_queue, _} = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Jobs} -> lists:foreach(fun print_json/1, Jobs), ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, Command, _Options) ->
  ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% interface for daemonizing script
%%%---------------------------------------------------------------------------

%% @doc Convert an error to a printable form.

-spec format_error(term()) ->
  iolist() | binary().

%% command line parsing
format_error({arguments, {bad_command, Command}}) ->
  ["invalid command: ", Command];
format_error({arguments, {bad_option, Option}}) ->
  ["invalid option: ", Option];
format_error({arguments, {bad_timeout, _Arg}}) ->
  "invalid timeout value";
format_error({arguments, {bad_pruning_age, _Arg}}) ->
  "invalid log pruning age";
format_error({arguments, {bad_queue_name, _Arg}}) ->
  "invalid queue name";
format_error({arguments, undefined_queue}) ->
  "queue name not provided";
format_error({arguments, undefined_job}) ->
  "job ID not provided";
format_error({arguments, {excessive_argument, Arg}}) ->
  ["excessive argument: ", Arg];

%% config file handling (`start')
format_error({config_read, Error}) ->
  ["config reading error: ", file:format_error(Error)];
format_error({config_format, Error}) ->
  ["config file parsing error: ", format_etoml_error(Error)];

%% errors from setup_applications()
format_error({configure, {bad_option, Option}}) ->
  ["invalid config option: ", Option];
format_error({configure, no_listen_addresses}) ->
  "no listen addresses in configuration";
%% prepare_indira_options() and setup_logging()
format_error({configure, bad_option}) ->
  "invalid config option in [erlang] section";
format_error({configure, {log_file, Error}}) ->
  ["error opening log file: ", indira_disk_h:format_error(Error)];

%% TODO: `indira_app:daemonize()' errors

%% request sending errors
format_error({send, bad_request_format}) ->
  "invalid request format (programmer's error)";
format_error({send, bad_reply_format}) ->
  "invalid reply format (daemon's error)";
format_error({send, timeout}) ->
  "operation timed out";
format_error({send, Error}) ->
  io_lib:format("request sending error: ~1024p", [Error]);

format_error({unknown_status, Status}) ->
  io_lib:format("unknown status: ~1024p", [Status]);

%% `gen_indira_cli' callback returns invalid value
format_error({bad_return_value, Value}) ->
  io_lib:format("invalid return value from callback: ~1024p", [Value]);

format_error(Message) when is_binary(Message) ->
  Message;
format_error(Reason) ->
  io_lib:format("unrecognized error: ~1024p", [Reason]).

%% @doc Return a printable help message.

-spec help(string()) ->
  iolist().

help(Script) ->
  _Usage = [
    "HarpCaller daemon.\n",
    "\n",
    "Daemon control:\n",
    "  ", Script, " [--socket=...] start [--debug] [--config=...] [--pidfile=...]\n",
    "  ", Script, " [--socket=...] status [--wait [--timeout=...]]\n",
    "  ", Script, " [--socket=...] stop [--timeout=...] [--print-pid]\n",
    "  ", Script, " [--socket=...] reload\n",
    "Jobs:\n",
    "  ", Script, " [--socket=...] list\n",
    "  ", Script, " [--socket=...] info <job-id>\n",
    "  ", Script, " [--socket=...] cancel <job-id>\n",
    "Job queues:\n",
    "  ", Script, " [--socket=...] queue-list\n",
    "  ", Script, " [--socket=...] queue-list <queue-name>\n",
    "  ", Script, " [--socket=...] queue-cancel <queue-name>\n",
    "Hosts registry:\n",
    "  ", Script, " [--socket=...] hosts-list\n",
    "  ", Script, " [--socket=...] hosts-refresh\n",
    "Distributed Erlang support:\n",
    "  ", Script, " [--socket=...] dist-erl-start\n",
    "  ", Script, " [--socket=...] dist-erl-stop\n",
    "Log handling/rotation:\n",
    "  ", Script, " [--socket=...] prune-jobs [--age=<days>]\n",
    "  ", Script, " [--socket=...] reopen-logs\n"
  ].

%%%---------------------------------------------------------------------------
%%% config file related helpers
%%%---------------------------------------------------------------------------

%% @doc Load configuration from TOML file.

-spec read_config_file(file:filename()) ->
  {ok, config()} | {error, {config_format | config_read, term()}}.

read_config_file(ConfigFile) ->
  case file:read_file(ConfigFile) of
    {ok, Content} ->
      case etoml:parse(Content) of
        {ok, Config} -> {ok, Config};
        {error, Reason} -> {error, {config_format, Reason}}
      end;
    {error, Reason} ->
      {error, {config_read, Reason}}
  end.

format_etoml_error({invalid_key, Line}) ->
  io_lib:format("line ~B: invalid key name", [Line]);
format_etoml_error({invalid_group, Line}) ->
  io_lib:format("line ~B: invalid group name", [Line]);
format_etoml_error({invalid_date, Line}) ->
  io_lib:format("line ~B: invalid date format", [Line]);
format_etoml_error({invalid_number, Line}) ->
  io_lib:format("line ~B: invalid number value or forgotten quotes", [Line]);
format_etoml_error({invalid_array, Line}) ->
  io_lib:format("line ~B: invalid array format", [Line]);
format_etoml_error({invalid_string, Line}) ->
  io_lib:format("line ~B: invalid string format", [Line]);
format_etoml_error({undefined_value, Line}) ->
  io_lib:format("line ~B: value not provided", [Line]);
format_etoml_error({duplicated_key, Key}) ->
  io_lib:format("duplicated key: ~s", [Key]).

%% @doc Configure environment (Erlang, Indira, main app) from loaded config.

-spec setup_applications(config(), #opts{}) ->
  {ok, [indira_app:daemon_option()]} | {error, term()}.

setup_applications(Config, Options) ->
  case configure_harpcaller(Config, Options) of
    ok ->
      case setup_logging(Config, Options) of
        ok -> prepare_indira_options(Config, Options);
        {error, Reason} -> {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%%----------------------------------------------------------
%% configure_harpcaller() {{{

%% @doc Configure the main application.

-spec configure_harpcaller(config(), #opts{}) ->
  ok | {error, {bad_option, binary()} | no_listen_addresses}.

configure_harpcaller(GlobalConfig, _Options) ->
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
  case indira_app:set_env(fun config_check/3, GlobalConfig, SetSpecs) of
    ok ->
      ok;
    {error, {Key, _EnvKey, bad_option}} ->
      {error, {bad_option, Key}};
    {error, {_Key, _EnvKey, no_listen_addresses}} ->
      {error, no_listen_addresses}
  end.

%% @doc Validate values loaded from config file.
%%
%% @see indira_app:set_env/3

config_check(_Key, _EnvKey, undefined = _Value) ->
  ignore;

config_check(<<"listen">> = _Key, _EnvKey, Specs) ->
  try [parse_listen_spec(S) || S <- Specs] of
    [] -> {error, no_listen_addresses};
    Addresses -> {ok, Addresses}
  catch
    error:_ -> {error, bad_option}
  end;

config_check(<<"stream_directory">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_check(<<"default_timeout">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_check(<<"max_exec_time">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_check(<<"ca_file">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_check(<<"known_certs_file">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_check(<<"host_db_script">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_check(<<"host_db">> = _Key, _EnvKey, Path) when is_binary(Path) ->
  {ok, binary_to_list(Path)};

config_check(<<"host_db_refresh">> = _Key, _EnvKey, T) when is_integer(T), T > 0 ->
  ok;

config_check(<<"log_handlers">> = _Key, _EnvKey, Handlers) ->
  try
    {ok, [{binary_to_atom(H, utf8), []} || H <- Handlers]}
  catch
    error:_ -> {error, bad_option}
  end;

config_check(_Key, _EnvKey, _Value) ->
  {error, bad_option}.

%% @doc Parse a listen address to a tuple suitable for HTTP or TCP listeners.
%%
%% @see config_check/3

parse_listen_spec(Spec) ->
  case binary:split(Spec, <<":">>) of
    [<<"*">>, Port] ->
      {any, list_to_integer(binary_to_list(Port))};
    [Host, Port] ->
      {binary_to_list(Host), list_to_integer(binary_to_list(Port))}
  end.

%% }}}
%%----------------------------------------------------------
%% setup_logging() {{{

%% @doc Configure Erlang logging.
%%   This function also starts SASL application if requested.

-spec setup_logging(config(), #opts{}) ->
  ok | {error, bad_option | {log_file, file:posix()} |
               bad_logger_module}.

setup_logging(Config, _Options = #opts{options = CLIOpts}) ->
  case proplists:get_bool(debug, CLIOpts) of
    true -> ok = application:start(sasl);
    false -> ok
  end,
  ErlangConfig = proplists:get_value(<<"erlang">>, Config, []),
  case proplists:get_value(<<"log_file">>, ErlangConfig) of
    File when is_binary(File) ->
      % XXX: see also `harpcaller_command_handler:handle_command()'
      ok = indira_app:set_option(harpcaller, error_logger_file, File),
      case indira_disk_h:install(error_logger, File) of
        ok -> ok;
        {error, Reason} -> {error, {log_file, Reason}}
      end;
    undefined ->
      ok;
    _ ->
      {error, bad_option}
  end.

%% }}}
%%----------------------------------------------------------
%% prepare_indira_options() {{{

%% @doc Prepare options for {@link indira_app:daemonize/2} from loaded config.

-spec prepare_indira_options(config(), #opts{}) ->
  {ok, [indira_app:daemon_option()]} | {error, term()}.

prepare_indira_options(GlobalConfig, _Options = #opts{options = CLIOpts}) ->
  % TODO: precise pinpointing what option was invalid
  ErlangConfig = proplists:get_value(<<"erlang">>, GlobalConfig, []),
  try
    PidFile = proplists:get_value(pidfile, CLIOpts),
    % PidFile is already a string or undefined
    NodeName = proplists:get_value(<<"node_name">>, ErlangConfig),
    true = (is_binary(NodeName) orelse NodeName == undefined),
    NameType = proplists:get_value(<<"name_type">>, ErlangConfig),
    true = (NameType == undefined orelse
            NameType == <<"longnames">> orelse NameType == <<"shortnames">>),
    Cookie = case proplists:get_value(<<"cookie_file">>, ErlangConfig) of
      CookieFile when is_binary(CookieFile) -> {file, CookieFile};
      undefined -> none
    end,
    NetStart = proplists:get_bool(<<"distributed_immediate">>, ErlangConfig),
    true = is_boolean(NetStart),
    IndiraOptions = [
      {pidfile, PidFile},
      {node_name, ensure_atom(NodeName)},
      {name_type, ensure_atom(NameType)},
      {cookie, Cookie},
      {net_start, NetStart}
    ],
    {ok, IndiraOptions}
  catch
    error:_ ->
      {error, bad_option}
  end.

%% @doc Ensure a value is an atom.

-spec ensure_atom(binary() | atom()) ->
  atom().

ensure_atom(Value) when is_atom(Value) -> Value;
ensure_atom(Value) when is_binary(Value) -> binary_to_atom(Value, utf8).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% various helpers
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parsing command line arguments {{{

%% @doc Command line argument parser for {@link indira_cli:folds/3}.

-spec cli_opt(string() | [string()], #opts{}) ->
  #opts{} | {error, help | bad_option | bad_command | excessive_argument
                    | bad_pruning_age | bad_timeout | bad_queue_name}.

cli_opt("-h" = _Arg, _Opts) ->
  {error, help};
cli_opt("--help" = _Arg, _Opts) ->
  {error, help};

cli_opt("--socket=" ++ Socket = _Arg, Opts) ->
  cli_opt(["--socket", Socket], Opts);
cli_opt("--socket" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--socket", Socket] = _Arg, Opts) ->
  _NewOpts = Opts#opts{admin_socket = Socket};

cli_opt("--pidfile=" ++ Path = _Arg, Opts) ->
  cli_opt(["--pidfile", Path], Opts);
cli_opt("--pidfile" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--pidfile", Path] = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{pidfile, Path} | CLIOpts]};

cli_opt("--config=" ++ Path = _Arg, Opts) ->
  cli_opt(["--config", Path], Opts);
cli_opt("--config" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--config", Path] = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{config, Path} | CLIOpts]};

cli_opt("--timeout=" ++ Timeout = _Arg, Opts) ->
  cli_opt(["--timeout", Timeout], Opts);
cli_opt("--timeout" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--timeout", Timeout] = _Arg, Opts = #opts{options = CLIOpts}) ->
  case make_integer(Timeout) of
    {ok, Seconds} when Seconds > 0 ->
      % NOTE: we need timeout in milliseconds
      _NewOpts = Opts#opts{options = [{timeout, Seconds * 1000} | CLIOpts]};
    _ ->
      {error, bad_timeout}
  end;

cli_opt("--age=" ++ Age = _Arg, Opts) ->
  cli_opt(["--age", Age], Opts);
cli_opt("--age" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--age", Age] = _Arg, Opts = #opts{options = CLIOpts}) ->
  case make_integer(Age) of
    {ok, Days} when Days > 0 ->
      _NewOpts = Opts#opts{options = [{age, Days} | CLIOpts]};
    _ ->
      {error, bad_pruning_age}
  end;

cli_opt("--debug" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{debug, true} | CLIOpts]};

cli_opt("--wait" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{wait, true} | CLIOpts]};

cli_opt("--print-pid" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{print_pid, true} | CLIOpts]};

cli_opt("-" ++ _ = _Arg, _Opts) ->
  {error, bad_option};

cli_opt(Arg, Opts = #opts{op = undefined}) ->
  case Arg of
    "start"  -> Opts#opts{op = start};
    "status" -> Opts#opts{op = status};
    "stop"   -> Opts#opts{op = stop};
    "reload" -> Opts#opts{op = reload_config};
    "prune-jobs"  -> Opts#opts{op = prune_jobs};
    "reopen-logs" -> Opts#opts{op = reopen_logs};
    "dist-erl-start" -> Opts#opts{op = dist_start};
    "dist-erl-stop"  -> Opts#opts{op = dist_stop};
    "list"   -> Opts#opts{op = list_jobs};
    "info"   -> Opts#opts{op = {job_info, undefined}};
    "cancel" -> Opts#opts{op = {cancel_job, undefined}};
    "hosts-list"    -> Opts#opts{op = list_hosts};
    "hosts-refresh" -> Opts#opts{op = refresh_hosts};
    "queue-list"    -> Opts#opts{op = list_queues};
    "queue-cancel"  -> Opts#opts{op = {cancel_queue, undefined}};
    _ -> {error, bad_command}
  end;

cli_opt(JobID = _Arg, Opts = #opts{op = {job_info, undefined}}) ->
  _NewOpts = Opts#opts{op = {job_info, JobID}};

cli_opt(JobID = _Arg, Opts = #opts{op = {cancel_job, undefined}}) ->
  _NewOpts = Opts#opts{op = {cancel_job, JobID}};

cli_opt(Queue = _Arg, Opts = #opts{op = list_queues}) ->
  case indira_json:decode(Queue) of
    {ok, Struct} -> _NewOpts = Opts#opts{op = {list_queue, Struct}};
    {error, _} -> {error, bad_queue_name}
  end;

cli_opt(Queue = _Arg, Opts = #opts{op = {cancel_queue, undefined}}) ->
  case indira_json:decode(Queue) of
    {ok, Struct} -> _NewOpts = Opts#opts{op = {cancel_queue, Struct}};
    {error, _} -> {error, bad_queue_name}
  end;

cli_opt(_Arg, _Opts) ->
  {error, excessive_argument}.

%% @doc Helper to convert string to integer.
%%
%%   Doesn't die on invalid argument.

-spec make_integer(string()) ->
  {ok, integer()} | {error, badarg}.

make_integer(String) ->
  try list_to_integer(String) of
    Integer -> {ok, Integer}
  catch
    error:badarg -> {error, badarg}
  end.

%% }}}
%%----------------------------------------------------------
%% printing lines to STDOUT and STDERR {{{

%% @doc Print a string to STDOUT, ending it with a new line.

-spec println(iolist() | binary()) ->
  ok.

println(Line) ->
  io:put_chars([Line, $\n]).

%% @doc Print a JSON structure to STDOUT, ending it with a new line.

-spec print_json(indira_json:struct()) ->
  ok.

print_json(Struct) ->
  {ok, JSON} = indira_json:encode(Struct),
  io:put_chars([JSON, $\n]).

%% @doc Print a string to STDERR, ending it with a new line.

-spec printerr(iolist() | binary()) ->
  ok.

printerr(Line) ->
  io:put_chars(standard_error, [Line, $\n]).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

%% @doc Load and set `harpcaller' application config from a config file.
%%
%%   Function intended for use in reloading config in the runtime.
%%
%%   Errors are formatted with {@link format_error/1}.

-spec load_app_config(file:filename(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_app_config(ConfigFile, Options) ->
  case read_config_file(ConfigFile) of
    {ok, Config} ->
      % FIXME: for the two options (`stream_directory' and `host_db_script')
      % that (a) are mandatory, (b) have no default values, and (c) take
      % effect immediately after being set, we're just assuming that they are
      % present in configuration file
      ok = reset_harpcaller_config(),
      case configure_harpcaller(config_defaults(Config), Options) of
        ok ->
          ok = reset_harpcaller_unset_options(Config),
          case load_error_logger_config(Config, Options) of
            ok -> load_indira_config(Config, Options);
            {error, Message} -> {error, Message}
          end;
        {error, Reason} ->
          {error, iolist_to_binary(format_error({configure, Reason}))}
      end;
    {error, Reason} ->
      {error, iolist_to_binary(format_error(Reason))}
  end.

%%----------------------------------------------------------
%% load_error_logger_config() {{{

%% @doc Set destination file for {@link error_logger}/{@link
%%   indira_disk_h}.
%%
%% @see load_app_config/2

-spec load_error_logger_config(config(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_error_logger_config(Config, _Options) ->
  ErlangConfig = proplists:get_value(<<"erlang">>, Config, []),
  case proplists:get_value(<<"log_file">>, ErlangConfig) of
    File when is_binary(File) ->
      ok = indira_app:set_option(harpcaller, error_logger_file, File);
    undefined ->
      ok = application:unset_env(harpcaller, error_logger_file);
    _ ->
      {error, iolist_to_binary(format_error({configure, bad_config}))}
  end.

%% }}}
%%----------------------------------------------------------
%% load_indira_config() {{{

%% @doc Reconfigure Indira's network configuration for Erlang.
%%
%% @see load_app_config/2

-spec load_indira_config(config(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_indira_config(Config, Options) ->
  case prepare_indira_options(Config, Options) of
    {ok, IndiraOptions} ->
      case indira_app:distributed_reconfigure(IndiraOptions) of
        ok ->
          ok;
        {error, invalid_net_config = _Reason} ->
          {error, <<"invalid network configuration">>};
        {error, Reason} ->
          Message = io_lib:format("Erlang network reloading error: ~1024p",
                                  [Reason]),
          {error, iolist_to_binary(Message)}
      end;
    {error, bad_option} ->
      % errors in "[erlang]" section
      {error, iolist_to_binary(format_error({configure, bad_option}))}
  end.

%% }}}
%%----------------------------------------------------------
%% reset_harpcaller_config() {{{

%% @doc Reset `harpcaller' application's environment to default values.
%%
%%   Two types of keys are omitted: `configure', which is not really
%%   a configuration setting (keeps "config reload" function for later use)
%%   and the keys that cannot be reset freely to an arbitrary temporary value
%%   (because they are immediately used).
%%
%% @see config_defaults/1

reset_harpcaller_config() ->
  CurrentConfig = [
    Entry ||
    {Key, _} = Entry <- application:get_all_env(harpcaller),
    Key /= configure, % not really part of the configuration
    % these are immediately used, so they need special care
    Key /= ca_file,
    Key /= known_certs_file,
    Key /= stream_directory,
    Key /= host_db_script,
    Key /= host_db_refresh,
    Key /= default_timeout,
    Key /= max_exec_time
  ],
  DefaultConfig = dict:from_list(harpcaller_default_env()),
  lists:foreach(
    fun({Key, _}) ->
      case dict:find(Key, DefaultConfig) of
        {ok, Value} -> application:set_env(harpcaller, Key, Value);
        error -> application:unset_env(harpcaller, Key)
      end
    end,
    CurrentConfig
  ),
  ok.

%% @doc Unset `harpcaller' non-mandatory options that were not set in the
%%   config.

reset_harpcaller_unset_options(Config) ->
  case proplists:get_value(<<"ca_file">>, Config) of
    undefined -> application:unset_env(harpcaller, ca_file);
    _ -> ok
  end,
  case proplists:get_value(<<"known_certs_file">>, Config) of
    undefined -> application:unset_env(harpcaller, known_certs_file);
    _ -> ok
  end,
  ok.

%% }}}
%%----------------------------------------------------------
%% config_defaults() {{{

%% @doc Populate config read from TOML file with values default for
%%   `harpcaller' application.
%%
%%   This function is used for reloading config and only works for settings
%%   that cannot be freely reset to default, because they're used immediately.
%%
%% @see reset_harpcaller_config/0

-spec config_defaults(config()) ->
  config().

config_defaults(Config) ->
  Defaults = harpcaller_default_env(),
  % it's a proplist and the first occurrence of the key is used, so appending
  % defaults is a good idea
  Config ++ [
    % these settings have no default values
    %{<<"ca_file">>,          proplists:get_value(ca_file,          Defaults)},
    %{<<"known_certs_file">>, proplists:get_value(known_certs_file, Defaults)},
    %{<<"stream_directory">>, proplists:get_value(stream_directory, Defaults)},
    %{<<"host_db_script">>,   proplists:get_value(host_db_script,   Defaults)},
    {<<"host_db_refresh">>,  proplists:get_value(host_db_refresh,  Defaults)},
    {<<"default_timeout">>,  proplists:get_value(default_timeout,  Defaults)},
    {<<"max_exec_time">>,    proplists:get_value(max_exec_time,    Defaults)}
  ].

%% }}}
%%----------------------------------------------------------
%% harpcaller_default_env() {{{

%% @doc Extract application's default environment from `harpcaller.app' file.

harpcaller_default_env() ->
  StatipAppFile = filename:join(code:lib_dir(harpcaller, ebin), "harpcaller.app"),
  {ok, [{application, harpcaller, AppKeys}]} = file:consult(StatipAppFile),
  proplists:get_value(env, AppKeys).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
