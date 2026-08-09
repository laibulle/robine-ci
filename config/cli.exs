import Config

# The escript runs application libraries directly and never starts the server supervision tree.
# Keep this environment free of database, endpoint, and server-secret requirements.
config :logger, level: :warning
