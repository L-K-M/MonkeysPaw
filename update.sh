#!/usr/bin/env bash
# Update the checkout and rebuild the single-host sync server deployment.
# Usage: ./update.sh [branch] (default: main)
# Requires Git and Docker Compose >= 2.20.0; gh is optional.
# Keep POSIX shell syntax so this also runs on macOS Bash 3.2.
set -eu

script_dir=$(dirname -- "$0")
CDPATH='' cd -- "$script_dir"
if [ ! -f .env ]; then
  printf '%s\n' 'Warning: .env is missing; prepare it from .env.example before deployment.' >&2
fi

if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Usage: ./update.sh [branch] (default: main)' >&2
  exit 2
fi
branch=${1:-main}

if gh_command=$(command -v gh); then
  :
else
  gh_command=
  for candidate in ../gh ../bin/gh ../gh*/bin/gh; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      gh_command=$candidate
      break
    fi
  done
fi

git check-ref-format --branch "$branch" >/dev/null
checkout_status=$(git status --porcelain --untracked-files=normal --ignore-submodules=none)
if [ -n "$checkout_status" ]; then
  printf '%s\n' 'Refusing to update a dirty checkout; commit or remove local changes first.' >&2
  exit 1
fi

git checkout "$branch" --
checked_out_ref=$(git symbolic-ref --quiet HEAD) || {
  status=$?
  printf '%s\n' 'Refusing to update: checkout is detached; resolve branch/tag name collisions first.' >&2
  exit "$status"
}
if [ "$checked_out_ref" != "refs/heads/$branch" ]; then
  printf '%s\n' 'Refusing to update: checkout did not select the named branch.' >&2
  exit 1
fi

git fetch origin "$branch"
# A pull can succeed with local-only commits; refuse them before either sync path.
if git merge-base --is-ancestor HEAD FETCH_HEAD; then
  :
else
  status=$?
  printf '%s\n' 'Refusing to update: local commits are ahead of or diverged from origin; resolve them first.' >&2
  exit "$status"
fi

if [ -n "$gh_command" ] && "$gh_command" repo sync --branch "$branch"; then
  :
else
  printf '%s\n' 'Warning: gh unavailable or sync failed; trying git pull --ff-only.' >&2
  git pull --ff-only origin "$branch"
fi

configured_services=$(docker compose config --services)
# No profile filter: Caddy may have been started with --profile tls only once.
running_services=$(docker compose ps --services --status running)
set --
case "
$configured_services
$running_services
" in
  *"
caddy
"*) set -- --profile tls ;;
esac

docker compose "$@" pull --ignore-buildable
docker compose "$@" build --pull
docker compose "$@" up -d --remove-orphans --wait --wait-timeout 120
docker image prune -f
docker compose "$@" ps
