#!/bin/bash
# Beispiel für <repo>/.claude/cloud-setup.sh
# Wird vom Basis-Skript beim Bau der Cloud-Umgebung im Repo-Root ausgeführt
# (max. 180 s, Fehler brechen das Setup nicht ab). Ergebnis landet im Snapshot.
# Vorteil gegenüber Hooks in .claude/settings.json: läuft auch in Projekt-Threads.

set -u

# PHP / TYPO3 / Shopware
if [ -f composer.json ]; then
  composer install --no-interaction --no-progress --prefer-dist || echo "composer install fehlgeschlagen"
fi

# Node (Lockfile entscheidet über den Paketmanager)
if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile
elif [ -f yarn.lock ];         then yarn install --frozen-lockfile
elif [ -f bun.lock ] || [ -f bun.lockb ]; then bun install --frozen-lockfile
elif [ -f package-lock.json ]; then npm ci --no-audit --no-fund
fi || echo "JS-Install fehlgeschlagen"

# Python
[ -f uv.lock ] && { uv sync || echo "uv sync fehlgeschlagen"; }

# Docker-Images vorab ziehen, damit sie im Snapshot liegen
if [ -f docker-compose.yml ] || [ -f compose.yaml ]; then
  cloud-services docker >/dev/null && docker compose pull -q || true
fi

exit 0
