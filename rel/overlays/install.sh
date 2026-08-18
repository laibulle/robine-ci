#!/bin/sh

set -eu

if [ ! -r RELEASE_PLATFORM ]; then
  echo "RELEASE_PLATFORM is missing from this server bundle" >&2
  exit 2
fi

. ./RELEASE_PLATFORM

case "${ROBINE_RUNTIME_IMAGE:-}" in
  ubuntu:24.04|ubuntu:26.04) ;;
  *)
    echo "unsupported or invalid release runtime image" >&2
    exit 2
    ;;
esac

mode=start

if [ "${1:-}" = "--prepare-only" ]; then
  mode=prepare
  shift
fi

host=${1:-}

case "$host" in
  ""|*[!a-z0-9.-]*|.*|*..*|*.)
    echo "usage: ./install.sh [--prepare-only] ci.example.com" >&2
    exit 64
    ;;
esac

if [ -e .env ]; then
  echo ".env already exists; refusing to overwrite instance secrets" >&2
  exit 2
fi

if [ "$mode" = "start" ]; then
  command -v docker >/dev/null 2>&1 || {
    echo "Docker Engine is required" >&2
    exit 3
  }

  docker compose version >/dev/null 2>&1 || {
    echo "Docker Compose v2 is required" >&2
    exit 3
  }
fi

random_hex() {
  od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

random_base64() {
  dd if=/dev/urandom bs=1 count="$1" 2>/dev/null | base64 | tr -d '\n'
}

postgres_password=$(random_hex 24)
secret_key_base=$(random_base64 64)
encryption_key=$(random_base64 32)
bootstrap_token=$(random_hex 24)
temporary=".env.tmp.$$"

umask 077
trap 'rm -f "$temporary"' EXIT HUP INT TERM

set -C
: >"$temporary"
set +C

{
  echo "ROBINE_HOST=$host"
  echo "ROBINE_PUBLIC_URL=https://$host"
  echo "ROBINE_BIND=0.0.0.0:4000"
  echo "DATABASE_URL=postgres://robine:$postgres_password@postgres/robine"
  echo "POSTGRES_PASSWORD=$postgres_password"
  echo "SECRET_KEY_BASE=$secret_key_base"
  echo "ROBINE_CI_SECRET_KEY=$encryption_key"
  echo "ROBINE_BOOTSTRAP_TOKEN=$bootstrap_token"
  echo "ROBINE_STORAGE_ROOT=/var/lib/robine/storage"
  echo "ROBINE_RUNTIME_IMAGE=$ROBINE_RUNTIME_IMAGE"
} >"$temporary"

chmod 600 "$temporary"
mv "$temporary" .env
trap - EXIT HUP INT TERM

if [ "$mode" = "prepare" ]; then
  echo "Prepared .env with mode 0600"
  exit 0
fi

docker compose --env-file .env up -d --wait

echo "Robine is ready at https://$host/setup"
echo "One-use bootstrap token: $bootstrap_token"
echo "Store .env in your encrypted backup before completing setup."
