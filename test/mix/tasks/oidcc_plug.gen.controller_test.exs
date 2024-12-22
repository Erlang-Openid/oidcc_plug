defmodule OidccPlug.Gen.ControllerTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "creates controller" do
    test_project(
      files: %{
        "lib/test_web/controllers/page_html/home.html.heex" => """
        <h1>Welcome to Phoenix!</h1>
        """,
        "lib/test_web/router.ex" => """
        defmodule TestWeb.Router do
          use TestWeb, :router

          pipeline :browser do
            plug :accepts, ["html"]
            plug :fetch_session
            plug :fetch_flash
            plug :protect_from_forgery
            plug :put_secure_browser_headers
          end

          scope "/", TestWeb do
            pipe_through :browser

            get "/", PageHtmlController, :home
          end
        end
        """
      }
    )
    |> Igniter.Project.Deps.add_dep({:phoenix, "~> 1.7"})
    |> Igniter.Project.Formatter.import_dep(:phoenix)
    |> Igniter.compose_task("igniter.add_extension", ["phoenix"])
    |> Igniter.compose_task("oidcc_plug.gen.controller", [
      "--name",
      "TestWeb.AuthController",
      "--provider",
      "Test.Provider",
      "--issuer",
      "https://accounts.google.com"
    ])
    |> puts_diff
  end
end
