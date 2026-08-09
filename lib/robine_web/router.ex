defmodule RobineWeb.Router do
  use RobineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RobineWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; connect-src 'self' ws: wss:; font-src 'self'; " <>
          "form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; " <>
          "script-src 'self'; style-src 'self' 'unsafe-inline'"
    }

    plug RobineWeb.Plugs.FetchCurrentActor
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :runner_api do
    plug :accepts, ["json", "gz"]
  end

  scope "/", RobineWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/sign-in", AuthController, :new
    post "/sign-in", AuthController, :create
    delete "/sign-out", AuthController, :delete
    get "/auth/oidc", AuthController, :oidc
    get "/auth/oidc/callback", AuthController, :oidc_callback
    get "/setup", AuthController, :bootstrap
    post "/setup", AuthController, :create_bootstrap

    live_session :authenticated,
      on_mount: [{RobineWeb.UserAuth, :require_authenticated}] do
      live "/pipelines", PipelineLive.Index, :index
      live "/pipelines/:id", PipelineLive.Show, :show
      live "/pipelines/:id/workflow", WorkflowRevisionLive.Show, :show
      live "/pipelines/:id/jobs/:job_id", JobLive.Show, :show
      live "/repositories", RepositoryLive.Index, :index
      live "/repositories/:id", RepositoryLive.Show, :show
    end

    live_session :maintainer,
      on_mount: [
        {RobineWeb.UserAuth, :require_authenticated},
        {RobineWeb.UserAuth, :require_maintainer}
      ] do
      live "/repositories/:id/secrets", RepositoryLive.Secrets, :index
    end

    live_session :administrator,
      on_mount: [
        {RobineWeb.UserAuth, :require_authenticated},
        {RobineWeb.UserAuth, :require_administrator}
      ] do
      live "/admin", AdminLive.Index, :index
    end
  end

  scope "/api/github", RobineWeb do
    pipe_through :api
    post "/webhooks", GitHubWebhookController, :create
  end

  scope "/api", RobineWeb do
    pipe_through :api
    post "/gitlab/webhooks", SourceControlWebhookController, :gitlab
    post "/forgejo/webhooks", SourceControlWebhookController, :forgejo
  end

  scope "/api/v1/runners", RobineWeb do
    pipe_through :runner_api
    post "/enroll", RunnerEnrollmentController, :create
    get "/attempts/:attempt_id/source", RunnerAttemptController, :source
    get "/attempts/:attempt_id/secrets", RunnerAttemptController, :secrets
    get "/attempts/:attempt_id/cache", RunnerAttemptController, :restore_cache
    put "/attempts/:attempt_id/cache", RunnerAttemptController, :save_cache
    get "/attempts/:attempt_id/artifacts", RunnerAttemptController, :download_artifact
    put "/attempts/:attempt_id/artifacts", RunnerAttemptController, :upload_artifact
  end

  scope "/health", RobineWeb do
    pipe_through :api
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", RobineWeb do
    get "/metrics", MetricsController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", RobineWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:robine, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RobineWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
