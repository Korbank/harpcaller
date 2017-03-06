%%%---------------------------------------------------------------------------
%%% @doc
%%%   Helper functions for working with X.509 certificates.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_x509).

%% public interface
-export([read_cert_file/1]).
-export([subject/1]).
-export([names/1, subject_common_name/1, subject_alt_names/1]).

-export_type([certificate/0, name/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-include_lib("public_key/include/public_key.hrl").

-type certificate() :: #'OTPCertificate'{}.
%% Record loaded using `-include_lib("public_key/include/public_key.hrl")'.

-type name() :: string() | inet:ip_address().
%% DNS name or IP address.

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Load certificates from a PEM file.

-spec read_cert_file(file:filename()) ->
  {ok, [certificate()]} | {error, file:posix()}.

read_cert_file(CertFile) ->
  case file:read_file(CertFile) of
    {ok, CertFileContent} ->
      PEMEntries = public_key:pem_decode(CertFileContent),
      OTPCerts = [
        public_key:pkix_decode_cert(DERCert, otp) ||
        {'Certificate', DERCert, not_encrypted} <- PEMEntries
      ],
      {ok, OTPCerts};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Extract subject names (commonName and alternative names) from
%%   certificate.
%%
%%   Certificate is assumed to have a commonName.
%%
%%   Only DNS and IP alternative names are returned.

-spec names(certificate()) ->
  [name()].

names(OTPCert) ->
  CommonName = subject_common_name(OTPCert),
  SubjectAltNames = subject_alt_names(OTPCert),
  [CommonName | SubjectAltNames].

%% @doc Extract subject from the certificate.

-spec subject(#'OTPCertificate'{}) ->
  [#'AttributeTypeAndValue'{}].

subject(_OTPCert = #'OTPCertificate'{
          tbsCertificate = #'OTPTBSCertificate'{subject = {rdnSequence, Attrs}}
        }) ->
  _Result = [A || AL <- Attrs, A <- AL].

%% @doc Extract subject commonName from certificate.
%%   Certificate is assumed to have one.

-spec subject_common_name(certificate()) ->
  string().

subject_common_name(OTPCert = #'OTPCertificate'{}) ->
  DNAttrs = subject(OTPCert),
  CNAttrValue = [
    V ||
    #'AttributeTypeAndValue'{type = ?'id-at-commonName', value = V} <- DNAttrs
  ],
  case CNAttrValue of
    [{utf8String, CN}] -> unicode:characters_to_list(CN, utf8);
    [CN] when is_list(CN) -> CN
  end.

%% @doc Extract subject alternative names from certificate, if any.

-spec subject_alt_names(certificate()) ->
  [name()].

subject_alt_names(_OTPCert = #'OTPCertificate'{
                    tbsCertificate = #'OTPTBSCertificate'{extensions = Exts}
                  }) ->
  case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID, Exts) of
    #'Extension'{extnValue = Values} ->
      _AltNames = [
        format_name(V) ||
        {Type, _} = V <- Values,
        Type == dNSName orelse Type == iPAddress
      ];
    false ->
      []
  end.

%%----------------------------------------------------------

%% @doc Format subject alternative name for {@link subject_alt_names/1}.

format_name({dNSName, Name}) ->
  Name;
format_name({iPAddress, [A,B,C,D] = _Addr}) ->
  {A,B,C,D};
format_name({iPAddress, [A1, A2, A3, A4, A5, A6, A7, A8, 
                         A9, A10, A11, A12, A13, A14, A15, A16] = _Addr}) ->
  {A1 * 256 + A2, A3 * 256 + A4, A5 * 256 + A6, A7 * 256 + A8,
   A9 * 256 + A10, A11 * 256 + A12, A13 * 256 + A14, A15 * 256 + A16}.

%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
