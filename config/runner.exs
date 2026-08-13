import Config

# The standalone runner is an outbound CLI process. It deliberately does not
# load production server configuration or require database, endpoint, or
# bootstrap secrets.
config :logger, level: :info
