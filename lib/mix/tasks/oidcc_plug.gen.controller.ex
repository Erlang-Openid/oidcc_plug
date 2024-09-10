defmodule Mix.Tasks.OidccPlug.Gen.Controller do
  @example "mix oidcc.gen.controller --name MyApp.AuthController --provider MyApp.OpenIDProvider --base-url /auth --issuer https://account.google.com --client-id client-id --client-secret client-secret"

  @shortdoc "Generate an auth controller for your OpenID provider"
  if !Code.ensure_loaded?(Igniter) do
    @shortdoc "#{@shortdoc} | Install `igniter` to use"
  end

  @moduledoc """
  #{@shortdoc}

  Generates an auth controller that starts the OpenID Connect flow and handles
  the result. Additionally, it will add the routes to your router.

  ## Example

  ```bash
  #{@example}
  ```

  ## Options

  * `--name` or `-n` - Name of the controller
  * `--provider` or `-p` - Name of the OpenID Provider
  * `--base-url` or `-b` - Base URL for the controller
  * `--issuer` or `-i` - Issuer URL of the OpenID Provider
  * `--client-id` - Client ID for the OpenID Provider
  * `--client-secret` - Client Secret for the OpenID Provider
  """

  if Code.ensure_loaded?(Igniter) do
    use Igniter.Mix.Task

    alias Igniter.Code.Module
    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Config
    alias Igniter.Project.IgniterConfig

    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        # dependencies to add
        adds_deps: [],
        # dependencies to add and call their associated installers, if they exist
        installs: [],
        # An example invocation
        example: @example,
        # Accept additional arguments that are not in your schema
        # Does not guarantee that, when composed, the only options you get are the ones you define
        extra_args?: false,
        # A list of environments that this should be installed in, only relevant if this is an installer.
        only: nil,
        # a list of positional arguments, i.e `[:file]`
        positional: [],
        # Other tasks your task composes using `Igniter.compose_task`, passing in the CLI argv
        # This ensures your option schema includes options from nested tasks
        composes: [],
        # `OptionParser` schema
        schema: [
          name: :string,
          provider: :string,
          base_url: :string,
          issuer: :string,
          client_id: :string,
          client_secret: :string
        ],
        # CLI aliases
        aliases: [n: :name, p: :provider, b: :base_url, i: :issuer]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter, argv) do
      # extract positional arguments according to `positional` above
      {_arguments, argv} = positional_args!(argv)
      # extract options according to `schema` and `aliases` above
      options = setup_options(argv, igniter)

      # Do your work here and return an updated igniter
      igniter
      |> IgniterConfig.setup()
      # TODO: Add Igniter ignore web folder
      |> setup_provider(options)
      |> setup_config(options)
      |> generate_controller(options)
      |> add_routes(options)
    end

    defp setup_options(argv, igniter) do
      argv
      |> options!()
      |> Keyword.update(
        :name,
        Phoenix.web_module_name(igniter, "AuthController"),
        &Module.parse/1
      )
      |> Keyword.update(
        :provider,
        Module.module_name(igniter, "OpenIDProvider"),
        &Module.parse/1
      )
      |> Keyword.put_new(:base_url, "/auth")
      |> Keyword.put(:app_name, Igniter.Project.Application.app_name(igniter))
    end

    defp setup_provider(igniter, options) do
      Igniter.compose_task(igniter, "oidcc.gen.provider_configuration_worker", [
        "--name",
        inspect(options[:provider]),
        "--issuer",
        options[:issuer],
        "--client-id",
        options[:client_id],
        "--client-secret",
        options[:client_secret]
      ])
    end

    defp setup_config(igniter, options) do
      env_prefix =
        options[:provider] |> Macro.underscore() |> String.upcase() |> String.replace("/", "_")

      client_id_config =
        case Keyword.fetch(options, :issuer) do
          {:ok, issuer} ->
            quote do
              System.get_env(unquote("#{env_prefix}_CLIENT_ID"), unquote(issuer))
            end

          :error ->
            quote do
              System.fetch_env!(unquote("#{env_prefix}_CLIENT_ID"))
            end
        end

      client_secret_config =
        case Keyword.fetch(options, :issuer) do
          {:ok, issuer} ->
            quote do
              System.get_env(unquote("#{env_prefix}_CLIENT_SECRET"), unquote(issuer))
            end

          :error ->
            quote do
              System.fetch_env!(unquote("#{env_prefix}_CLIENT_SECRET"))
            end
        end

      config =
        quote do
          [client_id: unquote(client_id_config), client_secret: unquote(client_secret_config)]
        end

      igniter
      |> Config.configure_new(
        "config.exs",
        options[:app_name],
        [options[:name], :provider],
        options[:provider]
      )
      |> Config.configure_new(
        "runtime.exs",
        options[:app_name],
        [options[:name]],
        {:code, config}
      )
    end

    defp generate_controller(igniter, options) do
      web_module = Phoenix.web_module(igniter)

      html_module_name =
        options[:name]
        |> inspect()
        |> String.trim_trailing("Controller")
        |> Kernel.<>("HTML")
        |> then(&Module.module_name(igniter, &1))

      html_path =
        html_module_name |> inspect() |> String.split(".") |> List.last() |> Macro.underscore()

      html_template_path =
        Path.join([
          igniter |> Igniter.Project.Module.proper_location(web_module) |> Path.rootname(".ex"),
          "controllers",
          html_path
        ])

      page_html_template_path =
        Path.join([
          igniter |> Igniter.Project.Module.proper_location(web_module) |> Path.rootname(".ex"),
          "controllers",
          "page_html"
        ])

      igniter
      |> Module.create_module(
        options[:name],
        Sourceror.to_string(
          quote do
            defmodule unquote(options[:name]) do
              use unquote(web_module), :controller

              plug(
                Oidcc.Plug.Authorize,
                [
                  provider:
                    Application.compile_env(unquote(options[:app_name]), [__MODULE__, :provider]),
                  client_id: &__MODULE__.client_id/0,
                  client_secret: &__MODULE__.client_secret/0,
                  redirect_uri: &__MODULE__.callback_uri/0
                ]
                when action in [:authorize]
              )

              plug(
                Oidcc.Plug.AuthorizationCallback,
                [
                  provider:
                    Application.compile_env(unquote(options[:app_name]), [__MODULE__, :provider]),
                  client_id: &__MODULE__.client_id/0,
                  client_secret: &__MODULE__.client_secret/0,
                  redirect_uri: &__MODULE__.callback_uri/0
                ]
                when action in [:callback]
              )

              def authorize(conn, _params), do: conn

              def callback(
                    %Plug.Conn{
                      private: %{Oidcc.Plug.AuthorizationCallback => {:ok, {_token, userinfo}}}
                    } =
                      conn,
                    params
                  ) do
                conn
                |> put_session("oidcc_claims", userinfo)
                |> redirect(
                  to:
                    case params[:state] do
                      nil -> "/"
                      state -> state
                    end
                )
              end

              def callback(
                    %Plug.Conn{private: %{Oidcc.Plug.AuthorizationCallback => {:error, reason}}} =
                      conn,
                    _params
                  ) do
                conn
                |> put_status(400)
                |> render(:error, reason: reason)
              end

              @doc false
              def client_id,
                do: Application.fetch_env!(unquote(options[:app_name]), __MODULE__)[:client_id]

              @doc false
              def client_secret,
                do:
                  Application.fetch_env!(unquote(options[:app_name]), __MODULE__)[:client_secret]

              @doc false
              def callback_uri,
                do:
                  url(
                    unquote(
                      {:sigil_p, [delimiter: "\""],
                       [{:<<>>, [], ["#{options[:base_url]}/callback"]}, []]}
                    )
                  )
            end
          end
        )
      )
      |> Module.create_module(
        html_module_name,
        Sourceror.to_string(
          quote do
            defmodule unquote(html_module_name) do
              use unquote(web_module), :html

              embed_templates(unquote("#{html_path}/*"))
            end
          end
        )
      )
      |> Igniter.create_new_file(Path.join(html_template_path, "error.html.heex"), """
      <p>error:</p>

      <pre><%= inspect(@reason, pretty: true) %></pre>
      """)
      |> Igniter.update_file(Path.join(page_html_template_path, "home.html.heex"), fn current ->
        Rewrite.Source.update(current, :content, """
        #{Rewrite.Source.get(current, :content)}

        <div class="px-4 py-10 sm:px-6 sm:py-28 lg:px-8 xl:px-28 xl:py-32">
          <div class="mx-auto max-w-xl lg:mx-0">
            <div class="group -mx-2 -my-0.5 inline-flex items-center gap-3 px-2 py-0.5">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="h-4 w-4">
                <path stroke-linecap="round" stroke-linejoin="round" d="M15.75 6a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0zM4.501 20.118a7.5 7.5 0 0114.998 0A17.933 17.933 0 0112 21.75c-2.676 0-5.216-.584-7.499-1.632z" />
              </svg>

              <%= case Plug.Conn.get_session(@conn, "oidcc_claims") do %>
                <% nil -> %>
                  <a href={ ~p"#{options[:base_url]}/authorize" }>
                    Log In
                  </a>
                <% %{"sub" => sub} -> %>
                  <span class="text-base text-zinc-600">Logged in as <%= sub %></span>
              <% end %>
            </div>
          </div>
        </div>
        """)
      end)
    end

    defp add_routes(igniter, options) do
      case Phoenix.select_router(igniter) do
        {igniter, nil} ->
          Igniter.add_warning(igniter, """
          No Phoenix router found, skipping Route installation.

          See the Getting Started guide for instructions on installing AshJsonApi with `plug`.
          If you have yet to set up Phoenix, you'll have to do that manually and then rerun this installer.
          """)

        {igniter, router} ->
          Igniter.Libs.Phoenix.add_scope(
            igniter,
            options[:base_url],
            """
            pipe_through [:browser]

            get "/authorize", #{inspect(options[:name])}, :authorize
            get "/callback", #{inspect(options[:name])}, :callback
            post "/callback", #{inspect(options[:name])}, :callback
            """,
            router: router,
            arg2: Phoenix.web_module(igniter)
          )
      end
    end
  else
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'oidcc.gen.controller' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
