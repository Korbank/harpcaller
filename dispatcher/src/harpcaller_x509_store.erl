%%%---------------------------------------------------------------------------
%%% @doc
%%%   X.509 certificate store.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_x509_store).

-behaviour(gen_server).

%% public interface
-export([reload/0, known/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------

-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

-record(state, {
  cert_file :: file:filename(),
  certs :: cert_store(),
  last_change :: change_time()
}).

-type cert_store() :: dict().
-type change_time() :: {MTime :: integer(), CTime :: integer()}.

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Reload certificate file, even if it hasn't changed.

-spec reload() ->
  ok | {error, term()}.

reload() ->
  gen_server:call(?MODULE, reload).

%% @doc Check if the certificate is known by certificate store.

-spec known(harpcaller_x509:certificate()) ->
  boolean().

known(Certificate = #'OTPCertificate'{}) ->
  % do at least some of the work in caller
  CertSubject = harpcaller_x509:subject(Certificate),
  gen_server:call(?MODULE, {check_presence, CertSubject, Certificate}).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start certificate store process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start certificate store process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([] = _Args) ->
  case application:get_env(known_certs_file) of
    {ok, CAFile} ->
      case read_certs(CAFile) of
        {ok, Certs, CMTime} ->
          State = #state{
            cert_file = CAFile,
            certs = store(Certs),
            last_change = CMTime
          },
          {ok, State};
        {error, _Reason} ->
          State = #state{
            cert_file = CAFile,
            certs = store([])
          },
          {ok, State}
      end;
    undefined ->
      State = #state{
        cert_file = undefined,
        certs = store([])
      },
      {ok, State}
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call(reload = _Request, _From, State = #state{cert_file = CAFile}) ->
  case read_certs(CAFile) of
    {ok, NewCerts, NewCMTime} ->
      NewState = State#state{
        certs = store(NewCerts),
        last_change = NewCMTime
      },
      {reply, ok, NewState};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({check_presence, CertSubject, Cert} = _Request, _From,
            State = #state{cert_file = CAFile}) ->
  case {stat_certs(CAFile), State} of
    {{ok, CMTime}, #state{last_change = CMTime}} ->
      % not changed since last read
      NewCertStore = State#state.certs,
      NewState = State;
    {{ok, _}, #state{}} ->
      % apparently the file has changed; reread
      {ok, NewCerts, NewCMTime} = read_certs(CAFile),
      NewCertStore = store(NewCerts),
      NewState = State#state{
        certs = NewCertStore,
        last_change = NewCMTime
      };
    {{error, _Reason}, #state{}} ->
      % file missing for some reason; pretend there's no problem and use last
      % known content
      NewCertStore = State#state.certs,
      NewState = State
  end,
  Reply = has(CertSubject, Cert, NewCertStore),
  {reply, Reply, NewState};

%% unknown calls
handle_call(Request, From, State) ->
  harpcaller_log:unexpected_call(Request, From, ?MODULE),
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(Request, State) ->
  harpcaller_log:unexpected_cast(Request, ?MODULE),
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

%% unknown messages
handle_info(Message, State) ->
  harpcaller_log:unexpected_info(Message, ?MODULE),
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

%% @doc Read file with known certificates.

-spec read_certs(file:filename()) ->
    {ok, [harpcaller_x509:certificate()], change_time()} | {error, term()}.

read_certs(File) ->
  case harpcaller_x509:read_cert_file(File) of
    {ok, Certs} ->
      % XXX: let's just hope nobody deletes or changes the file between
      % reading it and stating
      {ok, {_MTime, _CTime} = CMTime} = stat_certs(File),
      {ok, Certs, CMTime};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Read the change time of file with known certificates.

-spec stat_certs(file:filename()) ->
  {ok, change_time()} | {error, term()}.

stat_certs(File) ->
  case file:read_file_info(File, [{time, posix}]) of
    {ok, #file_info{mtime = MTime, ctime = CTime}} ->
      {ok, {MTime, CTime}};
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------

%% @doc Build a store with X.509 certificates.

-spec store([harpcaller_x509:certificate()]) ->
  cert_store().

store(Certs) ->
  lists:foldl(fun add/2, dict:new(), Certs).

%% @doc Add a certificate to store.

-spec add(harpcaller_x509:certificate(), cert_store()) ->
  cert_store().

add(Cert, CertStore) ->
  Subject = harpcaller_x509:subject(Cert),
  dict:append(Subject, Cert, CertStore).

%% @doc Check if the store has this particular X.509 certificate.

-spec has(harpcaller_x509:certificate(), list(), cert_store()) ->
  boolean().

has(Subject, Cert, CertStore) ->
  case dict:find(Subject, CertStore) of
    {ok, SameSubjectCerts} ->
      lists:any(fun(C) -> C =:= Cert end, SameSubjectCerts);
    error ->
      false
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
