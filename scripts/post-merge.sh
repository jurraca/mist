#!/bin/bash
set -e

mix deps.get
mix ecto.migrate
