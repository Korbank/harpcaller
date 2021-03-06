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

%% gen_indira_cli callbacks
-export([parse_arguments/2]).
-export([handle_command/2, format_request/2, handle_reply/3]).

%% interface for harpcaller_command_handler
-export([reload/1]).

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
      | list_jobs | cancel_job | job_info
      | list_hosts | refresh_hosts
      | list_queue | cancel_queue
      | dist_start | dist_stop
      | prune_jobs | reopen_logs,
  admin_socket :: file:filename(),
  options :: [{atom(), term()}],
  args = [] :: [string()]
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
  case gen_indira_cli:folds(fun cli_opt/2, EmptyOptions, Args) of
    % irregular operations
    {ok, Options = #opts{op = start,  args = []}} -> {ok, start,  Options};
    {ok, Options = #opts{op = status, args = []}} -> {ok, status, Options};
    {ok, Options = #opts{op = stop,   args = []}} -> {ok, stop,   Options};

    % operations with a arguments
    {ok, Options = #opts{op = job_info, args = [ID], admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, {job_info, ID}, Options};
    {ok, _Options = #opts{op = job_info, args = []}} ->
      {error, {help, too_little_args}};

    {ok, Options = #opts{op = cancel_job, args = [ID], admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, {cancel_job, ID}, Options};
    {ok, _Options = #opts{op = cancel_job, args = []}} ->
      {error, {help, too_little_args}};

    {ok, Options = #opts{op = list_queue, args = [ID], admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, {list_queue, ID}, Options};
    {ok, Options = #opts{op = list_queue, args = [], admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, list_queues, Options};

    {ok, Options = #opts{op = cancel_queue, args = [ID], admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, {cancel_queue, ID}, Options};
    {ok, _Options = #opts{op = cancel_queue, args = []}} ->
      {error, {help, too_little_args}};

    {ok, _Options = #opts{op = _, args = [_|_]}} ->
      {error, {help, too_many_args}};

    {ok, _Options = #opts{op = undefined}} ->
      help;

    {ok, Options = #opts{op = Command, admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, Command, Options};

    {error, {help, _Arg}} ->
      help;

    {error, {_Reason, _Arg} = Error} ->
      {error, {help, Error}}
  end.

%% }}}
%%----------------------------------------------------------
%% handle_command() {{{

%% @private
%% @doc Execute commands more complex than "request -> reply -> print".

handle_command(start = _Command,
               _Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  ConfigFile = proplists:get_value(config, CLIOpts),
  SASLApp = case proplists:get_bool(debug, CLIOpts) of
    true -> sasl;
    false -> undefined
  end,
  PidFile = proplists:get_value(pidfile, CLIOpts),
  case config_load(ConfigFile) of
    {ok, AppEnv, IndiraOpts, ErrorLoggerLog} ->
      case install_error_logger_handler(ErrorLoggerLog) of
        ok ->
          ok = indira:set_env(harpcaller, AppEnv),
          indira:daemonize(harpcaller, [
            {listen, [{?ADMIN_SOCKET_TYPE, Socket}]},
            {command, {?ADMIN_COMMAND_MODULE, []}},
            {reload, {?MODULE, reload, [ConfigFile]}},
            {start_before, SASLApp},
            {pidfile, PidFile} |
            IndiraOpts
          ]);
        {error, Reason} ->
          {error, {log_file, Reason}}
      end;
    {error, Reason} ->
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
  case gen_indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, {socket, _, Reason}} when Reason == timeout, Wait;
                                      Reason == econnrefused;
                                      Reason == enoent ->
      % FIXME: what to do when a command got sent, but no reply was received?
      % (Reason == timeout)
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `gen_indira_cli:execute()' returns
  end;

handle_command(stop = Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  Timeout = proplists:get_value(timeout, CLIOpts, infinity),
  Opts = [{timeout, Timeout}],
  {ok, Request} = format_request(Command, Options),
  case gen_indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, {socket, _, Reason}} when Reason == closed;
                                      Reason == econnrefused;
                                      Reason == enoent ->
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `gen_indira_cli:execute()' returns
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
format_request(list_jobs = _Command, _Options = #opts{options = CLIOpts}) ->
  AllJobs = proplists:get_bool(all, CLIOpts),
  Request = ?ADMIN_COMMAND_MODULE:format_request({list_jobs, AllJobs}),
  {ok, Request};
format_request({list_queue, Arg} = _Command, _Options) ->
  case indira_json:decode(Arg) of
    {ok, ID} -> {ok, ?ADMIN_COMMAND_MODULE:format_request({list_queue, ID})};
    {error, _} -> {error, {help, bad_queue_name}}
  end;
format_request({cancel_queue, Arg} = _Command, _Options) ->
  case indira_json:decode(Arg) of
    {ok, ID} -> {ok, ?ADMIN_COMMAND_MODULE:format_request({cancel_queue, ID})};
    {error, _} -> {error, {help, bad_queue_name}}
  end;
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
    {error, Reason} ->
      {error, Reason};
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
    {error, Message} when is_binary(Message) ->
      printerr(["reload error: ", Message]),
      {error, 1};
    {error, Errors} ->
      printerr("reload errors:"),
      lists:foreach(
        fun({Part, Error}) -> printerr(["  ", Part, ": ", Error]) end,
        Errors
      ),
      {error, 1}
  end;

handle_reply(Reply, list_jobs = Command, _Options = #opts{options = CLIOpts}) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Jobs} ->
      case proplists:get_bool(queue, CLIOpts) of
        true ->
          lists:foreach(fun print_json/1, Jobs);
        false ->
          lists:foreach(
            fun(J) -> print_json(proplists:delete(<<"queue">>, J)) end,
            Jobs
          )
      end,
      ok;
    {error, Reason} ->
      {error, Reason}
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

%%----------------------------------------------------------
%% format_error() {{{

%% @doc Convert an error to a printable form.

-spec format_error(Reason :: term()) ->
  iolist() | binary().

%% errors from `parse_arguments()' (own and `cli_opt()' + argument)
format_error({bad_command, Command}) ->
  ["invalid command: ", Command];
format_error({bad_option, Option}) ->
  ["invalid option: ", Option];
format_error({{bad_timeout, Value}, _Arg}) ->
  ["invalid timeout value: ", Value];
format_error({{bad_pruning_age, Value}, _Arg}) ->
  ["invalid pruning age: ", Value];
format_error(too_many_args) ->
  "too many arguments for this operation";
format_error(too_little_args) ->
  "too little arguments for this operation";
format_error(bad_queue_name) ->
  % this actually comes from `format_request()', but it's a command line
  % arguments error
  "invalid queue name";

%% errors from `config_load()'
format_error({config, validate, {Section, Key, Line} = _Where}) ->
  ["config error: invalid value of ", format_toml_key(Section, Key),
    " (line ", integer_to_list(Line), ")"];
format_error({config, toml, Reason}) ->
  ["config error: ", toml:format_error(Reason)];
format_error({config, {missing, Section, Key}}) ->
  ["config error: missing required key ", format_toml_key(Section, Key)];

format_error({log_file, Error}) ->
  ["error opening log file: ", indira_disk_h:format_error(Error)];

%% errors from `gen_indira_cli:execute()'
format_error({send, Error}) ->
  ["command sending error: ", gen_indira_cli:format_error(Error)];
format_error({bad_return_value, _} = Error) ->
  gen_indira_cli:format_error(Error);

%% errors from `indira:daemonize()'
format_error({indira, _} = Error) ->
  indira:format_error(Error);

%% `handle_reply()'
format_error(Reason) when is_binary(Reason) ->
  % error message ready to print to the console
  Reason;
format_error({unknown_status, Status}) ->
  % `$SCRIPT status' returned unrecognized status
  ["unrecognized status: ", format_term(Status)];
format_error(unrecognized_reply) -> % see `?ADMIN_COMMAND_MODULE:parse_reply()'
  "unrecognized reply to the command (programmer's error)";
format_error('TODO') ->
  "command not implemented yet";

format_error(Reason) ->
  ["unrecognized error: ", format_term(Reason)].

%% @doc Serialize an arbitrary term to a single line of text.

-spec format_term(term()) ->
  iolist().

format_term(Term) ->
  io_lib:print(Term, 1, 16#ffffffff, -1).

%% @doc Format TOML path (section + key name) for error message.

-spec format_toml_key([string()], string()) ->
  iolist().

format_toml_key(Section, Key) ->
  [$", [[S, $.] || S <- Section], Key, $"].

%% }}}
%%----------------------------------------------------------
%% help() {{{

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
    "  ", Script, " [--socket=...] list [--all] [--queue]\n",
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

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% loading configuration
%%%---------------------------------------------------------------------------

%% @doc Install {@link error_logger} handler that writes to a file.

-spec install_error_logger_handler(file:filename() | undefined) ->
  ok | {error, file:posix() | system_limit}.

install_error_logger_handler(undefined = _ErrorLoggerLog) ->
  indira_disk_h:remove(error_logger),
  ok;
install_error_logger_handler(ErrorLoggerLog) ->
  indira_disk_h:reopen(error_logger, ErrorLoggerLog).

%% @doc Update application environment from config file and instruct
%%   application's processes to reread their parameters.

-spec reload(file:filename()) ->
  ok | {error, binary() | [{atom(), indira_json:struct()}]}.

reload(Path) ->
  case config_load(Path) of
    {ok, AppEnv, IndiraOpts, ErrorLoggerLog} ->
      case install_error_logger_handler(ErrorLoggerLog) of
        ok ->
          case indira:distributed_reconfigure(IndiraOpts) of
            ok ->
              ok = indira:set_env(harpcaller, AppEnv),
              reload_subsystems();
            {error, Reason} ->
              Message = format_error(Reason),
              {error, iolist_to_binary(Message)}
          end;
        {error, Reason} ->
          Message = format_error({log_file, Reason}),
          {error, iolist_to_binary(Message)}
      end;
    {error, Reason} ->
      Message = format_error(Reason),
      {error, iolist_to_binary(Message)}
  end.

%%----------------------------------------------------------
%% reloading subsystems {{{

%% @doc Reload all subsystems that need to be told that config was changed.

-spec reload_subsystems() ->
  ok | {error, [{atom(), indira_json:struct()}]}.

reload_subsystems() ->
  Subsystems = [logger, tcp_listen, x509_store, hostdb],
  case lists:foldl(fun reload_subsystem/2, [], Subsystems) of
    [] -> ok;
    [_|_] = Errors -> {error, lists:reverse(Errors)}
  end.

%% @doc Workhorse for {@link reload_subsystems/0}.

-spec reload_subsystem(atom(), list()) ->
  list().

reload_subsystem(logger = Name, Errors) ->
  {ok, LogHandlers} = application:get_env(harpcaller, log_handlers),
  case harpcaller_log:reload(LogHandlers) of
    {ok, _ReloadCandidates} ->
      % gen_event handlers that maybe need reloading (neither
      % `harpcaller_stdout_h' nor `harpcaller_syslog_h' need it, though, and
      % they're the only supported handlers at this point)
      Errors;
    {error, Reason} ->
      [{Name, iolist_to_binary(format_term(Reason))} | Errors]
  end;

reload_subsystem(tcp_listen = Name, Errors) ->
  case harpcaller_tcp_sup:reload() of
    ok ->
      Errors;
    {error, TCPErrors} ->
      % list of errors, potentially one per socket listener
      [{Name, [iolist_to_binary(format_term(E)) || E <- TCPErrors]} | Errors]
  end;

reload_subsystem(x509_store = Name, Errors) ->
  case harpcaller_x509_store:reload() of
    ok ->
      Errors;
    {error, Reason} ->
      % file reading error
      [{Name, iolist_to_binary(file:format_error(Reason))} | Errors]
  end;

reload_subsystem(hostdb = Name, Errors) ->
  case harpcaller_hostdb:reopen() of
    ok ->
      Errors;
    {error, Reason} ->
      [{Name, iolist_to_binary(format_term(Reason))} | Errors]
  end.

%% }}}
%%----------------------------------------------------------

%% @doc Load configuration file.

-spec config_load(file:filename()) ->
  {ok, AppEnv, IndiraOpts, ErrorLoggerLog} | {error, Reason}
  when AppEnv :: [{atom(), term()}],
       IndiraOpts :: [indira:daemon_option()],
       ErrorLoggerLog :: file:filename() | undefined,
       Reason :: {config, validate, Where :: term()}
               | {config, toml, toml:toml_error()}
               | {config, {missing, Section :: [string()], Key :: string()}}.

config_load(Path) ->
  case toml:read_file(Path, {fun config_validate/4, []}) of
    {ok, Config} ->
      case config_build(Config) of
        {ok, AppEnv, IndiraOpts, ErrorLoggerLog} ->
          {ok, DefaultEnv} = indira:default_env(harpcaller),
          {ok, AppEnv ++ DefaultEnv, IndiraOpts, ErrorLoggerLog};
        {error, {missing, _Section, _Key} = Reason} ->
          {error, {config, Reason}}
      end;
    {error, {validate, Where, badarg}} ->
      {error, {config, validate, Where}};
    {error, Reason} ->
      {error, {config, toml, Reason}}
  end.

%%----------------------------------------------------------
%% config_build() {{{

%% @doc Build application's and Indira's configuration from values read from
%%   config file.

-spec config_build(toml:config()) ->
  {ok, AppEnv, IndiraOpts, ErrorLoggerLog} | {error, Reason}
  when AppEnv :: [{atom(), term()}],
       IndiraOpts :: [indira:daemon_option()],
       ErrorLoggerLog :: file:filename() | undefined,
       Reason :: {missing, Section :: [string()], Key :: string()}.

config_build(TOMLConfig) ->
  try build_app_env(TOMLConfig) of
    {ok, AppEnv} ->
      IndiraOpts = build_indira_opts(TOMLConfig),
      ErrorLoggerLog = proplists:get_value(error_logger_file, AppEnv),
      {ok, AppEnv, IndiraOpts, ErrorLoggerLog};
    {error, {missing, _Section, _Key} = Reason} ->
      {error, Reason}
  catch
    throw:{error, {missing, _Section, _Key} = Reason} ->
      {error, Reason}
  end.

build_indira_opts(TOMLConfig) ->
  make_proplist(TOMLConfig, [], [
    {["erlang"], "node_name", node_name},
    {["erlang"], "name_type", name_type},
    {["erlang"], "cookie_file", cookie},
    {["erlang"], "distributed_immediate", net_start}
  ]).

build_app_env(TOMLConfig) ->
  {ok, DefaultEnv} = indira:default_env(harpcaller),
  AppEnv = make_proplist(TOMLConfig, DefaultEnv, [
    {[], "listen",            listen},
    {[], "stream_directory",  stream_directory},
    {[], "default_timeout",   default_timeout},
    {[], "max_exec_time",     max_exec_time},
    {[], "max_age",           max_age},
    {[], "ca_file",           ca_file},
    {[], "known_certs_file",  known_certs_file},
    {[], "host_db_script",    host_db_script},
    {[], "host_db",           host_db},
    {[], "host_db_refresh",   host_db_refresh},
    {[], "log_handlers",      log_handlers},
    {["erlang"], "log_file",  error_logger_file}
  ]),
  % check required options that have no good default values (mainly, paths to
  % things)
  case app_env_defined([stream_directory, host_db, host_db_script], AppEnv) of
    ok -> {ok, AppEnv};
    % compare `make_proplist()' call above
    {missing, stream_directory} -> {error, {missing, [], "stream_directory"}};
    {missing, host_db}          -> {error, {missing, [], "host_db"}};
    {missing, host_db_script}   -> {error, {missing, [], "host_db_script"}}
  end.

app_env_defined([] = _Vars, _AppEnv) ->
  ok;
app_env_defined([Key | Rest] = _Vars, AppEnv) ->
  case proplists:is_defined(Key, AppEnv) of
    true -> app_env_defined(Rest, AppEnv);
    false -> {missing, Key}
  end.

make_proplist(TOMLConfig, Init, Keys) ->
  lists:foldr(
    fun({Section, Name, EnvKey}, Acc) ->
      case toml:get_value(Section, Name, TOMLConfig) of
        {_Type, Value} -> [{EnvKey, Value} | Acc];
        none -> Acc
      end
    end,
    Init, Keys
  ).

%% }}}
%%----------------------------------------------------------
%% config_validate() {{{

%% @doc Validate values read from TOML file (callback for
%%   {@link toml:read_file/2}).

-spec config_validate(Section :: toml:section(), Key :: toml:key(),
                      Value :: toml:toml_value(), Arg :: term()) ->
  ok | {ok, term()} | ignore | {error, badarg}.

config_validate([], "listen", Value, _Arg) ->
  case Value of
    {array, {string, AddrSpecs}} ->
      try lists:map(fun parse_listen/1, AddrSpecs) of
        Addrs -> {ok, Addrs}
      catch
        _:_ -> {error, badarg}
      end;
    %{array, {empty, []}} -> % listen address list must be non-empty
    %  {error, badarg};
    _ ->
      {error, badarg}
  end;

config_validate([], "stream_directory", Value, _Arg) -> valid(path, Value);
config_validate([], "default_timeout",  Value, _Arg) -> valid(time, Value);
config_validate([], "max_exec_time",    Value, _Arg) -> valid(time, Value);
config_validate([], "max_age",          Value, _Arg) -> valid(time, Value);

config_validate([], "ca_file",          Value, _Arg) -> valid(path, Value);
config_validate([], "known_certs_file", Value, _Arg) -> valid(path, Value);

config_validate([], "host_db_script",   Value, _Arg) -> valid(path, Value);
config_validate([], "host_db",          Value, _Arg) -> valid(path, Value);
config_validate([], "host_db_refresh",  Value, _Arg) -> valid(time, Value);

config_validate([], "log_handlers", Value, _Arg) ->
  case Value of
    {array, {string, Names}} ->
      {ok, [{list_to_atom(N), []} || N <- Names]};
    {array, {empty, []}} ->
      {ok, []};
    _ ->
      {error, badarg}
  end;
config_validate(["erlang"], "log_file", Value, _Arg) ->
  valid(path, Value);

config_validate(["erlang"], "node_name", Value, _Arg) ->
  case Value of
    {string, [_|_] = Name} -> {ok, list_to_atom(Name)};
    _ -> {error, badarg}
  end;
config_validate(["erlang"], "name_type", Value, _Arg) ->
  case Value of
    {string, "longnames"} -> {ok, longnames};
    {string, "shortnames"} -> {ok, shortnames};
    _ -> {error, badarg}
  end;
config_validate(["erlang"], "cookie_file", Value, _Arg) ->
  case Value of
    {string, [_|_] = Path} -> {ok, {file, Path}};
    _ -> {error, badarg}
  end;
config_validate(["erlang"], "distributed_immediate", Value, _Arg) ->
  case Value of
    {boolean, V} -> {ok, V};
    _ -> {error, badarg}
  end;

config_validate(_Section, _Key, _Value, _Arg) ->
  ignore.

%% @doc Validate a value from config according to its expected format.

-spec valid(Type :: path | time, Value :: toml:toml_value()) ->
  ok | {error, badarg}.

valid(path, {string, [_|_] = _Path}) -> ok;
valid(time, {integer, T}) when T > 0 -> ok;
valid(_Type, _Value) -> {error, badarg}.

%% @doc Parse listen address.
%%   Function crashes on invalid address format.

-spec parse_listen(string()) ->
  {any | inet:hostname(), inet:port_number()} | no_return().

parse_listen(AddrPort) ->
  case string:tokens(AddrPort, ":") of
    ["*", Port] -> {any, list_to_integer(Port)};
    [Addr, Port] -> {Addr, list_to_integer(Port)}
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% various helpers
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parsing command line arguments {{{

%% @doc Command line argument parser for {@link gen_indira_cli:folds/3}.

-spec cli_opt(string() | [string()], #opts{}) ->
  #opts{} | {error, help | Error}
  when Error :: bad_option | bad_command
              | {bad_timeout, string()}
              | {bad_pruning_age, string()}.

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
      {error, {bad_timeout, Timeout}}
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
      {error, {bad_pruning_age, Age}}
  end;

cli_opt("--debug" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{debug, true} | CLIOpts]};

cli_opt("--wait" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{wait, true} | CLIOpts]};

cli_opt("--print-pid" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{print_pid, true} | CLIOpts]};

cli_opt("--all" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{all, true} | CLIOpts]};

cli_opt("--queue" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{queue, true} | CLIOpts]};

cli_opt("-" ++ _ = _Arg, _Opts) ->
  {error, bad_option};

cli_opt(Arg, Opts = #opts{op = Op, args = OpArgs}) when Op /= undefined ->
  % `++' operator is a little costly, but considering how many arguments there
  % will be, the time it all takes will drown in Erlang startup
  _NewOpts = Opts#opts{args = OpArgs ++ [Arg]};

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
    "info"   -> Opts#opts{op = job_info};
    "cancel" -> Opts#opts{op = cancel_job};
    "hosts-list"    -> Opts#opts{op = list_hosts};
    "hosts-refresh" -> Opts#opts{op = refresh_hosts};
    "queue-list"    -> Opts#opts{op = list_queue};
    "queue-cancel"  -> Opts#opts{op = cancel_queue};
    _ -> {error, bad_command}
  end.

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
%%% vim:ft=erlang:foldmethod=marker
