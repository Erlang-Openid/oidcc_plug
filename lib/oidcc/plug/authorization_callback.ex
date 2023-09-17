defmodule Oidcc.Plug.AuthorizationCallback do
  @moduledoc """
  Retrieve Token for Code Flow Authorization Callback

  This plug does not send a response. Instead it will load and validate all
  token data and leave the rest to a controller action that will be executed
  after.

  ## Via `Phoenix.Router`

  ```elixir
  defmodule SampleAppWeb.Router do
    use Phoenix.Router

    # ...

    pipeline :oidcc_callback do
      plug Oidcc.Plug.AuthorizationCallback,
        provider: SampleApp.GoogleOpenIdConfigurationProvider,
        client_id: Application.compile_env!(:sample_app, [Oidcc.Plug.Authorize, :client_id]),
        client_secret: Application.compile_env!(:sample_app, [Oidcc.Plug.Authorize, :client_secret]),
        redirect_uri: "https://localhost:4000/oidcc/callback"
    end

    forward "/oidcc/authorize", to: Oidcc.Plug.Authorize,
      init_opts: [...]

    scope "/oidcc/callback", SampleAppWeb do
      pipe_through :oidcc_callback

      get "/", AuthController, :handle_callback
      post "/", AuthController, :handle_callback
    end
  end
  ```

  ## Via `Controller`

  ```elixir
  defmodule SampleAppWeb.AuthController do
    # ...

    plug Oidcc.Plug.AuthorizationCallback,
      provider: SampleApp.GoogleOpenIdConfigurationProvider,
      client_id: Application.compile_env!(:sample_app, [Oidcc.Plug.Authorize, :client_id]),
      client_secret: Application.compile_env!(:sample_app, [Oidcc.Plug.Authorize, :client_secret]),
      redirect_uri: "https://localhost:4000/oidcc/callback"
      when action in [:handle_callback]

    def handle_callback(
      %Plug.Conn{private: %{
        Oidcc.Plug.AuthorizationCallback => {:ok, {token, userinfo}}
      }},
      _params
    ) do
      # Handle Success

      conn
      |> put_session("auth_token", token)
      |> put_session("auth_userinfo", userinfo)
      |> redirect(to: "/")
    end

    def handle_callback(
      %Plug.Conn{private: %{
        Oidcc.Plug.AuthorizationCallback => {:error, reason}}
      },
      _params
    ) do
      # Handle Error

      conn
      |> put_status(400)
      |> render("error.html", reason: reason)
    end
  end
  ```
  """
  @moduledoc since: "0.1.0"

  @behaviour Plug

  import Plug.Conn,
    only: [get_session: 2, delete_session: 2, put_private: 3, get_peer_data: 1, get_req_header: 2]

  import Oidcc.Plug.Config, only: [evaluate_config: 1]

  @typedoc """
  Plug Configuration Options

  ## Options

  * `provider` - name of the `Oidcc.ProviderConfiguration.Worker`
  * `client_id` - OAuth Client ID to use for the introspection
  * `client_secret` - OAuth Client Secret to use for the introspection
  * `redirect_uri` - Where to redirect for callback
  * `check_useragent` - check if useragent is the same as before the
    authorization request
  * `check_peer_ip` - check if the client IP is the same as before the
    authorization request
  * `retrieve_userinfo` - whether to load userinfo from the provider
  * `request_opts` - request opts for http calls to provider
  """
  @typedoc since: "0.1.0"
  @type opts() :: [
          provider: GenServer.name(),
          client_id: String.t() | (-> String.t()),
          client_secret: String.t() | (-> String.t()),
          redirect_uri: String.t() | (-> String.t()),
          check_useragent: boolean(),
          check_peer_ip: boolean(),
          retrieve_userinfo: boolean(),
          request_opts: :oidcc_http_util.request_opts()
        ]

  @typedoc since: "0.1.0"
  @type error() ::
          :oidcc_client_context.error()
          | :oidcc_token.error()
          | :oidcc_userinfo.error()
          | :useragent_mismatch
          | :peer_ip_mismatch
          | {:missing_request_param, param :: String.t()}

  @impl Plug
  def init(opts),
    do:
      Keyword.validate!(opts, [
        :provider,
        :client_id,
        :client_secret,
        :redirect_uri,
        check_useragent: true,
        check_peer_ip: true,
        retrieve_userinfo: true,
        request_opts: %{}
      ])

  @impl Plug
  def call(%Plug.Conn{params: params, body_params: body_params} = conn, opts) do
    provider = Keyword.fetch!(opts, :provider)
    client_id = opts |> Keyword.fetch!(:client_id) |> evaluate_config()
    client_secret = opts |> Keyword.fetch!(:client_secret) |> evaluate_config()
    redirect_uri = opts |> Keyword.fetch!(:redirect_uri) |> evaluate_config()

    params = Map.merge(params, body_params)

    %{nonce: nonce, peer_ip: peer_ip, useragent: useragent} =
      case get_session(conn, "Oidcc.Plug.Authorize") do
        nil -> %{nonce: :any, peer_ip: nil, useragent: nil}
        %{} = session -> session
      end

    check_peer_ip? = Keyword.fetch!(opts, :check_peer_ip)
    check_useragent? = Keyword.fetch!(opts, :check_useragent)
    retrieve_userinfo? = Keyword.fetch!(opts, :retrieve_userinfo)

    result =
      with :ok <- check_peer_ip(conn, peer_ip, check_peer_ip?),
           :ok <- check_useragent(conn, useragent, check_useragent?),
           {:ok, code} <- fetch_request_param(params, "code"),
           scope = Map.get(params, "scope", "openid"),
           scopes = :oidcc_scope.parse(scope),
           token_opts =
             opts
             |> Keyword.take([:request_opts])
             |> Map.new()
             |> Map.merge(%{nonce: nonce, scope: scopes, redirect_uri: redirect_uri}),
           {:ok, token} <-
             retrieve_token(
               code,
               provider,
               client_id,
               client_secret,
               retrieve_userinfo?,
               token_opts
             ),
           {:ok, userinfo} <-
             retrieve_userinfo(token, provider, client_id, client_secret, retrieve_userinfo?) do
        {:ok, {token, userinfo}}
      end

    conn
    |> delete_session("Oidcc.Plug.Authorize")
    |> put_private(__MODULE__, result)
  end

  @spec check_peer_ip(
          conn :: Plug.Conn.t(),
          peer_ip :: :inet.ip_address() | nil,
          check_peer_ip? :: boolean()
        ) :: :ok | {:error, error()}
  defp check_peer_ip(conn, peer_ip, check_peer_ip?)
  defp check_peer_ip(_conn, _peer_ip, false), do: :ok
  defp check_peer_ip(_conn, nil, true), do: :ok

  defp check_peer_ip(%Plug.Conn{} = conn, peer_ip, true) do
    case get_peer_data(conn) do
      %{address: ^peer_ip} -> :ok
      %{} -> {:error, :peer_ip_mismatch}
    end
  end

  @spec check_useragent(
          conn :: Plug.Conn.t(),
          useragent :: String.t() | nil,
          check_useragent? :: boolean()
        ) :: :ok | {:error, error()}
  defp check_useragent(conn, useragent, check_useragent?)
  defp check_useragent(_conn, _useragent, false), do: :ok
  defp check_useragent(_conn, nil, true), do: :ok

  defp check_useragent(%Plug.Conn{} = conn, useragent, true) do
    case get_req_header(conn, "user-agent") do
      [^useragent | _rest] -> :ok
      _header -> {:error, :useragent_mismatch}
    end
  end

  @spec fetch_request_param(params :: %{String.t() => term()}, param :: String.t()) ::
          {:ok, term()} | {:error, error()}
  defp fetch_request_param(params, param) do
    case Map.fetch(params, param) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_request_param, param}}
    end
  end

  @spec retrieve_token(
          code :: String.t(),
          provider :: GenServer.name(),
          client_id :: String.t(),
          client_secret :: String.t(),
          retrieve_userinfo? :: boolean(),
          token_opts :: :oidcc_token.retrieve_opts()
        ) :: {:ok, Oidcc.Token.t()} | {:error, error()}
  defp retrieve_token(code, provider, client_id, client_secret, retrieve_userinfo?, token_opts) do
    case Oidcc.retrieve_token(code, provider, client_id, client_secret, token_opts) do
      {:ok, token} -> {:ok, token}
      {:error, {:none_alg_used, token}} when retrieve_userinfo? -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec retrieve_userinfo(
          token :: Oidcc.Token.t(),
          provider :: GenServer.name(),
          client_id :: String.t(),
          client_secret :: String.t(),
          retrieve_userinfo? :: true
        ) :: {:ok, :oidcc_jwt_util.claims()} | {:error, error()}
  @spec retrieve_userinfo(
          token :: Oidcc.Token.t(),
          provider :: GenServer.name(),
          client_id :: String.t(),
          client_secret :: String.t(),
          retrieve_userinfo? :: false
        ) :: {:ok, nil} | {:error, error()}
  defp retrieve_userinfo(token, provider, client_id, client_secret, retrieve_userinfo?)
  defp retrieve_userinfo(_token, _provider, _client_id, _client_secret, false), do: {:ok, nil}

  defp retrieve_userinfo(token, provider, client_id, client_secret, true),
    do: Oidcc.retrieve_userinfo(token, provider, client_id, client_secret, %{})
end
