#!/bin/bash
set -e

mix deps.get

if ! mix ecto.migrate 2>&1; then
  echo "[post-merge] Migration failed — recreating DB and retrying..."
  mix ecto.drop --force || true
  mix ecto.create
  mix ecto.migrate
fi
