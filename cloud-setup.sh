#!/bin/bash
# =============================================================================
#  Basis-Setup für Claude-Code-Cloud-Umgebungen (Ubuntu 24.04, läuft als root)
#
#  Läuft einmal pro Umgebung, bevor Claude startet. Danach wird das Dateisystem
#  als Snapshot gecacht (~7 Tage), solange das Skript unter ~5 Minuten bleibt.
#  Laufende Prozesse (DB, Docker) landen NICHT im Snapshot -> dafür gibt es
#  den Helfer `cloud-services`, den das Skript installiert.
#
#  Regeln, nach denen das Skript gebaut ist:
#    - darf nie mit Exit != 0 enden (sonst startet die Session nicht sauber)
#    - idempotent: mehrfach ausführen schadet nicht
#    - unabhängige Installs laufen parallel
#    - Umgebungsvariablen der Umgebung sind hier NOCH NICHT gesetzt
#
#  EINBINDEN im Feld "Setup script" der Umgebung:
#    bash <(curl -fsSL https://raw.githubusercontent.com/builtui/cloud-setup/main/cloud-setup.sh)
#  Schalter davor setzen: WITH_MARIADB=0 bash <(curl ...)
#  (Alternativ den ganzen Dateiinhalt einfügen, Limit 64 KB.)
#
#  ANPASSEN pro Umgebung: nur zwei Stellen
#    1. Block "KONFIGURATION" (Schalter, Extra-Pakete, Skills)
#    2. Block "PROJEKTSPEZIFISCH" ganz unten (composer install usw.)
# =============================================================================

set -u
exec </dev/null   # Kinder dürfen stdin nicht lesen. Darum NICHT per "curl | bash" starten, sondern "bash <(curl ...)"
LOG=/var/log/cloud-setup.log
exec > >(tee -a "$LOG") 2>&1
START=$(date +%s)
echo "== cloud-setup start $(date -Is) =="

# ----------------------------- KONFIGURATION ---------------------------------
# Werte lassen sich auch beim Aufruf überschreiben: WITH_MARIADB=0 bash setup.sh
: "${WITH_MARIADB:=1}"        # MariaDB-Server installieren (TYPO3/Shopware)
: "${WITH_AGENT_BROWSER:=1}"  # vercel-labs/agent-browser (Browser-CLI für Agenten)
: "${WITH_VERCEL_CLI:=0}"     # Vercel CLI (nur bei Vercel-Deployments sinnvoll)
: "${WITH_CF_CLI:=1}"         # Cloudflare-CLI cf (Beta, für Agenten gebaut), Telemetrie aus
: "${CF_CLI_VERSION:=1.0.0-rc.4}"
: "${WITH_EMULATE:=0}"        # vercel-labs/emulate: lokale Stellvertreter für GitHub, Resend, S3, Stripe …
: "${WITH_REACT_DOCTOR:=0}"   # react-doctor: Prüfung für React-Code (nur React-Projekte)
: "${EXPLORE_MODEL:=haiku}"   # Modell des Such-Helfers Explore (leer = Standard, also das Hauptmodell)
: "${WITH_SKILLS:=1}"         # Skills aus GitHub nach ~/.claude/skills holen
: "${WITH_REPO_HOOKS:=1}"     # <repo>/.claude/cloud-setup.sh jedes Repos ausführen
: "${LOCAL_CI:=1}"            # Sessions prüfen in der VM statt über GitHub Actions
: "${WITH_RULES:=1}"          # Grundregeln (Stack, Design, Arbeitsweise, additiv, Tests nach Gewicht)
: "${WITH_ONBOARDING:=1}"     # Ersteinrichtung pro Projekt (cloud-doctor, Skill projekt-einrichtung)
: "${WITH_WISSEN:=1}"         # Hinweis + Skill für gemeinsames Wissen (Ordner wissen/ im Repo WISSEN_REPO)
: "${WISSEN_REPO:=builtui/ops}"  # privates Repo, muss am Project hängen
: "${SHARED_RULES:=gemeinsam.md}"  # persönliche gemeinsame Anweisungen in diesem Repo, landen in ~/.claude/CLAUDE.md

# Zusätzliche apt-Pakete (Leerzeichen-getrennt)
APT_EXTRA="${APT_EXTRA:-}"
# Zusätzliche globale npm-Pakete
NPM_EXTRA="${NPM_EXTRA:-}"

# Orvel-Aufgaben-App (siehe Abschnitt 3b); URL des CLI-Downloads ohne Dateiname
: "${WITH_ORVEL:=0}"
: "${ORVEL_CLI_URL:=}"

# Vorschau aus der Cloud über ein privates Tailscale-Netz (Headscale), siehe 4c
: "${WITH_TAILSCALE:=0}"
: "${TAILSCALE_VERSION:=}"    # leer = aktuelle stabile Version beim Bau
: "${WITH_1PASSWORD:=0}"      # 1Password-CLI (op); bei WITH_TAILSCALE=1 immer dabei
: "${OP_VERSION:=2.42.0}"

# Skills: "<github-owner/repo>:<skill>[,<skill>...]"  (Leerzeichen-getrennt)
# Öffentliche Repos funktionieren immer. Private Repos nur, wenn sie an die
# Session angehängt sind -> eigene Skills besser auf claude.ai aktivieren.
# Bewusst klein halten: jede Skill-Beschreibung kostet in jeder Session Kontext.
# Weitere Quellen (alle getestet, öffentlich):
#   vercel-labs/agent-skills:react-best-practices,composition-patterns   (React/Next)
#   emilkowalski/skills:animate,review-animations,mobile-native         (UI/Motion)
#   mattpocock/skills:grill-me,diagnosing-bugs,tdd                      (Engineering)
#   humanlayer/skills:show-me,improve-claude-md
#   vercel-labs/portless:portless
# Design-Skills, auf die sich die Grundregeln beziehen:
DESIGN_SKILLS="emilkowalski/skills:emil-design-eng,apple-design jakubkrehel/skills:better-interface,better-ui,better-layout,better-typography,better-colors,better-accessibility,better-writing,better-motion leonxlnx/taste-skill:taste-skill"
SKILL_SOURCES="${SKILL_SOURCES:-vercel-labs/agent-skills:web-design-guidelines $DESIGN_SKILLS}"
# -----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
# Composer läuft hier als root und schaltet dann Plugins ab (TYPO3/Shopware brauchen sie)
export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1
for rc in /root/.bashrc /root/.profile; do
  grep -q COMPOSER_ALLOW_SUPERUSER "$rc" 2>/dev/null || \
    echo 'export COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1' >> "$rc"
done
grep -q COMPOSER_ALLOW_SUPERUSER /etc/environment 2>/dev/null || \
  printf 'COMPOSER_ALLOW_SUPERUSER=1\nCOMPOSER_NO_INTERACTION=1\n' >> /etc/environment
# Telemetrie der Cloudflare-Werkzeuge aus (cf, wrangler)
for rc in /root/.bashrc /root/.profile; do
  grep -q CF_SEND_TELEMETRY "$rc" 2>/dev/null || echo 'export CF_SEND_TELEMETRY=false WRANGLER_SEND_METRICS=false' >> "$rc"
done
grep -q CF_SEND_TELEMETRY /etc/environment 2>/dev/null || \
  printf 'CF_SEND_TELEMETRY=false\nWRANGLER_SEND_METRICS=false\n' >> /etc/environment
step() { echo; echo "-- $* ($(( $(date +%s) - START ))s)"; }
warn() { echo "!! WARNUNG: $*"; }

# 1) apt-Pakete ---------------------------------------------------------------
apt_job() {
  local pkgs="sqlite3 fd-find fzf shellcheck tree htop unzip zip rsync bat
              mariadb-client $APT_EXTRA"
  [ "$WITH_MARIADB" = 1 ] && pkgs="$pkgs mariadb-server"
  apt-get update -qq || warn "apt-get update fehlgeschlagen"
  # Pakete einzeln nachinstallieren, falls die Sammel-Installation scheitert
  apt-get install -y -qq --no-install-recommends $pkgs >/dev/null 2>&1 || {
    warn "Sammel-Install fehlgeschlagen, versuche einzeln"
    for p in $pkgs; do apt-get install -y -qq --no-install-recommends "$p" >/dev/null 2>&1 || warn "apt: $p"; done
  }
  # Ubuntu benennt fd/bat um -> gewohnte Namen verlinken
  command -v fd  >/dev/null || ln -sf "$(command -v fdfind)" /usr/local/bin/fd  2>/dev/null
  command -v bat >/dev/null || ln -sf "$(command -v batcat)" /usr/local/bin/bat 2>/dev/null
  # MariaDB nicht im Snapshot laufen lassen, Start übernimmt cloud-services
  service mariadb stop >/dev/null 2>&1 || true
  echo "apt fertig"
}

# 2) globale npm-Tools --------------------------------------------------------
npm_job() {
  local pkgs="$NPM_EXTRA"
  [ "$WITH_AGENT_BROWSER" = 1 ] && pkgs="$pkgs agent-browser"
  [ "$WITH_VERCEL_CLI" = 1 ]    && pkgs="$pkgs vercel"
  [ "$WITH_CF_CLI" = 1 ]        && pkgs="$pkgs cf@$CF_CLI_VERSION"
  [ "$WITH_EMULATE" = 1 ]       && pkgs="$pkgs emulate"
  [ "$WITH_REACT_DOCTOR" = 1 ]  && pkgs="$pkgs react-doctor"
  pkgs="$(echo $pkgs)"
  [ -z "$pkgs" ] && { echo "npm: nichts zu tun"; return; }
  npm install -g --silent --no-fund --no-audit $pkgs || warn "npm -g: $pkgs"
  echo "npm fertig: $pkgs"
}

# 3) Skills -------------------------------------------------------------------
skills_job() {
  [ "$WITH_SKILLS" = 1 ] || return 0
  mkdir -p /root/.claude/skills
  local tmp; tmp=$(mktemp -d)
  for src in $SKILL_SOURCES; do
    local repo="${src%%:*}" list="${src#*:}"
    local dir="$tmp/${repo//\//_}"
    if ! git clone -q --depth 1 "https://github.com/$repo.git" "$dir" 2>/dev/null; then
      warn "Skills: $repo nicht erreichbar (privat und nicht angehängt?)"; continue
    fi
    for s in ${list//,/ }; do
      local path
      path=$(find "$dir" -type f -name SKILL.md -path "*/$s/SKILL.md" | head -1)
      if [ -n "$path" ]; then
        rm -rf "/root/.claude/skills/$s"
        cp -r "$(dirname "$path")" "/root/.claude/skills/$s"
        echo "skill: $s (aus $repo)"
      else
        warn "Skill $s nicht in $repo gefunden"
      fi
    done
  done
  rm -rf "$tmp"
}

step "Installationen parallel starten"
apt_job    > /tmp/setup-apt.log    2>&1 &  P_APT=$!
npm_job    > /tmp/setup-npm.log    2>&1 &  P_NPM=$!
skills_job > /tmp/setup-skills.log 2>&1 &  P_SKL=$!
wait $P_APT; cat /tmp/setup-apt.log
wait $P_NPM; cat /tmp/setup-npm.log
wait $P_SKL; cat /tmp/setup-skills.log

# 3b) Orvel (optional): Sessions legen Aufgaben, die nur der Nutzer selbst
# erledigen kann, in der Aufgaben-App Orvel an. Braucht die Umgebungsvariable
# ORVEL_AGENT_CREDENTIAL (wird erst in der Session gelesen). Ohne Binary oder
# Credential bricht nichts ab.
if [ "$WITH_ORVEL" = 1 ] && [ -z "$ORVEL_CLI_URL" ]; then
  warn "WITH_ORVEL=1, aber ORVEL_CLI_URL fehlt, Orvel wird übersprungen"; WITH_ORVEL=0
fi
if [ "$WITH_ORVEL" = 1 ]; then
  step "Orvel-CLI installieren"
  if curl -fsSL --retry 3 "$ORVEL_CLI_URL/orvel-linux-x86_64" -o /tmp/orvel \
     && [ "$(sha256sum /tmp/orvel | cut -d' ' -f1)" = "$(curl -fsSL --retry 3 "$ORVEL_CLI_URL/orvel-linux-x86_64.sha256" | cut -d' ' -f1)" ]; then
    install -m 0755 /tmp/orvel /usr/local/bin/orvel && rm -f /tmp/orvel
  else
    warn "Orvel-CLI nicht geladen (noch nicht veröffentlicht oder Host gesperrt), Orvel wird übersprungen"
  fi
fi
if [ "$WITH_ORVEL" = 1 ] && command -v orvel >/dev/null; then

  cat > /usr/local/bin/orvel-todo <<'EOF'
#!/bin/bash
# orvel-todo: Aufgaben für den Nutzer in Orvel. Richtet beim ersten Aufruf die
# Agent-Replik ein (Secret ORVEL_AGENT_CREDENTIAL), danach zieht und schiebt
# jeder Befehl selbst.
#   orvel-todo lists                        Listen mit IDs (JSON)
#   orvel-todo add --list <id|Name> --title "..." [--notes "..."] --agent-ref <ref>
#   orvel-todo list create --name "..." --json   neue Liste (nur anlegen)
set -euo pipefail
command -v orvel >/dev/null || { echo "orvel-todo: orvel ist nicht installiert" >&2; exit 1; }
[ -n "${ORVEL_AGENT_CREDENTIAL:-}" ] || { echo "orvel-todo: Secret ORVEL_AGENT_CREDENTIAL fehlt in der Umgebung" >&2; exit 1; }
unset ORVEL_TOKEN
D="${XDG_DATA_HOME:-$HOME/.local/share}/orvel"
mkdir -p "$D" && chmod 700 "$D"
export ORVEL_DB="$D/replica.db"
if [ ! -f "$ORVEL_DB.sync-token" ]; then
  ( umask 077; printf '%s' "$ORVEL_AGENT_CREDENTIAL" > "$D/agent.json" )
  orvel sync join "$D/agent.json" >/dev/null || { rm -f "$D/agent.json"; echo "orvel-todo: Anmeldung am Sync-Dienst fehlgeschlagen" >&2; exit 1; }
  rm -f "$D/agent.json"
fi
case "${1:-}" in
  lists) orvel list list --json ;;
  add)   shift; orvel task create "$@" --json ;;
  *)     orvel "$@" ;;
esac
EOF
  chmod 0755 /usr/local/bin/orvel-todo

  mkdir -p /root/.claude/skills/orvel-todo
  cat > /root/.claude/skills/orvel-todo/SKILL.md <<'EOF'
---
name: orvel-todo
description: Put a task into the user's Orvel app when the session finds something that only the user can do outside the session. Not for approvals, questions, reviews or the session's own work.
---

# Tasks for the user in Orvel

Orvel is the user's own task app. It holds only what they themselves have to do. Add a task there when, during the work,
something comes up that only the user can do and that happens outside this session, for example:

- set a DNS record, a secret or a setting that only they have access to
- create an account, pay something, sign or send a contract
- call or write to a customer or another person
- test or do something on a device or in a place the session cannot reach

Never add:

- approvals, decisions, questions or "please review/merge": those stay in the thread
- anything the session can do itself, or tasks of agents
- reminders about this session's own progress

## How

1. `orvel-todo lists` shows the lists with their ids. Pick the list that fits the project or topic of this work
   (by name). If no list fits, create one named after the project or topic, short and in the user's words
   (`orvel-todo list create --name "Kunde X Shop" --json`), and use its id. Never rename, archive or delete lists.
   Say in your reply which list you used or created.
2. Add the task:

   ```bash
   orvel-todo add --list <list id> \
     --title "DNS-Eintrag für shop.example.de bei Hetzner setzen" \
     --notes "Warum und wo, ein bis zwei Sätze. Link: <thread or PR URL>" \
     --agent-ref "<session id>:<short-slug>"
   ```

   - Title in German, starts with a verb, says the concrete action.
   - Notes: the context the user needs to do it without opening the session, plus a link to the thread or PR.
   - `--agent-ref` makes the call safe to repeat: the same ref returns the existing task instead of a duplicate.
   - Leave column, dates and estimate out unless the work gives a real deadline (`--deadline 2026-12-01T12:00:00+01:00`).
3. Tell the user in one line in your reply that the task is in Orvel and in which list.

If `orvel-todo` fails (secret missing, service unreachable), mention the task in your reply instead and go on.
Only use `orvel-todo add`, `orvel-todo lists` and `orvel-todo list create`: do not move, change or complete the user's tasks.
EOF
fi

# Skills, die nur auf Zuruf laden sollen (Claude ruft sie nicht selbst auf)
SKILLS_MANUAL="${SKILLS_MANUAL:-taste-skill}"
for m in $SKILLS_MANUAL; do
  f="/root/.claude/skills/$m/SKILL.md"
  [ -f "$f" ] && ! grep -q '^disable-model-invocation:' "$f" && \
    sed -i '0,/^name:/s//disable-model-invocation: true\nname:/' "$f"
done

# agent-browser bringt seine eigene, versionsgleiche Skill-Doku mit
if [ "$WITH_AGENT_BROWSER" = 1 ] && command -v agent-browser >/dev/null; then
  mkdir -p /root/.claude/skills/agent-browser
  cat > /root/.claude/skills/agent-browser/SKILL.md <<'EOF'
---
name: agent-browser
description: Browser automation from the shell (open pages, click, fill forms, snapshot the accessibility tree, screenshots) for testing local dev servers or reading websites. Use when a task needs a real browser and no browser MCP tools are available.
---
`agent-browser` is installed globally and uses the preinstalled Chrome (`$CHROME_PATH`).
Before first use in a session, load the version-matched guide:

    agent-browser skills get core

Typical loop: `agent-browser open http://localhost:3000` -> `agent-browser snapshot`
(elements get refs like e1, e2) -> `agent-browser click e2` -> `agent-browser screenshot out.png`
-> `agent-browser close`.
EOF
fi

# 4) Helfer: Dienste pro Session starten --------------------------------------
step "Helfer cloud-services installieren"
cat > /usr/local/bin/cloud-services <<'EOF'
#!/bin/bash
# Startet Dienste, die im Snapshot nicht mitlaufen. Idempotent.
# Nutzung: cloud-services [docker] [mariadb] [postgres] [redis] [all] [status]
want="${*:-status}"; [ "$want" = all ] && want="docker mariadb postgres redis"
for s in $want; do
  case "$s" in
    docker)
      if ! docker info >/dev/null 2>&1; then
        (nohup dockerd >/var/log/dockerd.log 2>&1 &)
        for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
      fi
      docker info >/dev/null 2>&1 && echo "docker: läuft" || echo "docker: FEHLER, siehe /var/log/dockerd.log";;
    mariadb|mysql)  service mariadb start >/dev/null 2>&1; echo "mariadb: $(service mariadb status >/dev/null 2>&1 && echo läuft || echo FEHLER)";;
    postgres*)      service postgresql start >/dev/null 2>&1; echo "postgres: $(service postgresql status >/dev/null 2>&1 && echo läuft || echo FEHLER)";;
    redis)          service redis-server start >/dev/null 2>&1; echo "redis: $(redis-cli ping 2>/dev/null || echo FEHLER)";;
    status)
      docker info >/dev/null 2>&1 && echo "docker: läuft" || echo "docker: aus"
      for x in mariadb postgresql redis-server; do service $x status >/dev/null 2>&1 && echo "$x: läuft" || echo "$x: aus"; done;;
    *) echo "unbekannt: $s";;
  esac
done
EOF
chmod +x /usr/local/bin/cloud-services

# Docker-Container erreichen das Internet nur über den Proxy der Session.
# Dieser Wrapper reicht Proxy + CA-Zertifikat an einen Container durch.
cat > /usr/local/bin/docker-run-proxied <<'EOF'
#!/bin/bash
# Wie `docker run`, aber mit Netz über den Session-Proxy.
# Beispiel: docker-run-proxied --rm curlimages/curl -s https://pypi.org
exec docker run --network host \
  -e HTTPS_PROXY="$HTTPS_PROXY" -e https_proxy="$HTTPS_PROXY" -e NO_PROXY="$NO_PROXY" \
  -e SSL_CERT_FILE=/etc/ssl/certs/ccr-ca.crt -e NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ccr-ca.crt \
  -e REQUESTS_CA_BUNDLE=/etc/ssl/certs/ccr-ca.crt -e CURL_CA_BUNDLE=/etc/ssl/certs/ccr-ca.crt \
  -v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ccr-ca.crt:ro "$@"
EOF
chmod +x /usr/local/bin/docker-run-proxied

# cloud-warm: Abhängigkeiten eines Projekts im Setup VORAB laden, ohne
# Install-Skripte (die brauchen evtl. Umgebungsvariablen wie Lizenz-Keys, die
# das Setup noch nicht sieht). Füllt Paket-Cache + Playwright-Browser im Snapshot.
cat > /usr/local/bin/cloud-warm <<'EOF'
#!/bin/bash
# Nutzung: cloud-warm <projektordner> [browser ...]   z. B. cloud-warm mein-repo chromium webkit
dir="${1:-.}"; shift || true
cd "$dir" 2>/dev/null || { echo "cloud-warm: $dir fehlt"; exit 0; }
export COMPOSER_ALLOW_SUPERUSER=1
pwv=""
if [ -f pnpm-lock.yaml ]; then
  corepack enable >/dev/null 2>&1
  pnpm fetch --frozen-lockfile --ignore-scripts >/tmp/cloud-warm.log 2>&1 && echo "cloud-warm: pnpm-Store gefüllt ($dir)" || echo "cloud-warm: pnpm fetch fehlgeschlagen ($dir), siehe /tmp/cloud-warm.log"
  pwv=$(grep -oE "^  playwright@[0-9.]+" pnpm-lock.yaml | head -1 | cut -d@ -f2)
elif [ -f package-lock.json ]; then
  # npm kennt kein "fetch": einmal ohne Skripte installieren füllt ~/.npm, danach wieder weg
  npm ci --ignore-scripts --no-audit --no-fund >/tmp/cloud-warm.log 2>&1 && echo "cloud-warm: npm-Cache gefüllt ($dir)" || echo "cloud-warm: npm ci fehlgeschlagen ($dir)"
  pwv=$(node -e 'try{const l=require("./package-lock.json");console.log((l.packages||{})["node_modules/playwright"]?.version||"")}catch{}' 2>/dev/null)
  rm -rf node_modules
fi
if [ -f composer.lock ]; then
  composer install --no-interaction --no-progress --prefer-dist >/tmp/cloud-warm-composer.log 2>&1 && echo "cloud-warm: composer install ($dir)" || echo "cloud-warm: composer fehlgeschlagen ($dir)"
fi
[ -f uv.lock ] && { uv sync >/dev/null 2>&1 && echo "cloud-warm: uv sync ($dir)"; }
# Playwright-Browser in genau der Version, die das Projekt nutzt
if [ -n "$pwv" ] && [ $# -gt 0 ]; then
  npx -y "playwright@$pwv" install --with-deps "$@" >/tmp/cloud-warm-pw.log 2>&1 \
    && echo "cloud-warm: Playwright $pwv Browser: $*" \
    || echo "cloud-warm: Playwright-Browser fehlgeschlagen (cdn.playwright.dev erlaubt?), siehe /tmp/cloud-warm-pw.log"
fi
exit 0
EOF
chmod +x /usr/local/bin/cloud-warm

# cloud-install: Abhängigkeiten IN DER SESSION installieren (dann sind die
# Umgebungsvariablen da). Überspringt, wenn sich das Lockfile nicht geändert hat.
cat > /usr/local/bin/cloud-install <<'EOF'
#!/bin/bash
# Nutzung: cloud-install [projektordner]
dir="${1:-.}"; cd "$dir" || exit 1
export COMPOSER_ALLOW_SUPERUSER=1
lock=""; for f in pnpm-lock.yaml package-lock.json yarn.lock bun.lock composer.lock uv.lock; do [ -f "$f" ] && lock="$lock $f"; done
[ -z "$lock" ] && { echo "cloud-install: kein Lockfile in $dir"; exit 0; }
stamp=".cloud-install.stamp"; want=$(cat $lock | sha256sum | cut -c1-64)
[ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -d node_modules -o -d vendor -o -d .venv ] && { echo "cloud-install: $dir ist aktuell"; exit 0; }
log=/tmp/cloud-install-$(basename "$PWD").log; : > "$log"; ok=1
if   [ -f pnpm-lock.yaml ];    then corepack enable >/dev/null 2>&1; pnpm install --frozen-lockfile --prefer-offline >>"$log" 2>&1 || ok=0
elif [ -f package-lock.json ]; then npm ci --prefer-offline --no-audit --no-fund >>"$log" 2>&1 || ok=0
elif [ -f yarn.lock ];         then yarn install --frozen-lockfile >>"$log" 2>&1 || ok=0
elif [ -f bun.lock ];          then bun install --frozen-lockfile >>"$log" 2>&1 || ok=0
fi
[ -f composer.lock ] && { composer install --no-interaction --no-progress >>"$log" 2>&1 || ok=0; }
[ -f uv.lock ] && { uv sync >>"$log" 2>&1 || ok=0; }
if [ $ok = 1 ]; then echo "$want" > "$stamp"; echo "cloud-install: fertig ($dir)"
else
  echo "cloud-install: FEHLER in $dir, Ende von $log:"; tail -15 "$log"
  grep -q "license key is not set" "$log" && echo "Hinweis: Lizenz-Key fehlt in der Umgebung (Umgebungsvariable der Cloud-Umgebung setzen, nie im Chat)."
  exit 1
fi
EOF
chmod +x /usr/local/bin/cloud-install

# macOS-Chrome-Pfad nachbilden: Viele lokal geschriebene Skripte rufen
# "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" fest auf.
# Als root braucht Chrome --no-sandbox, der Wrapper hängt es an.
MAC_CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x /usr/bin/google-chrome ]; then
  mkdir -p "$(dirname "$MAC_CHROME")"
  printf '#!/bin/sh\nexec /usr/bin/google-chrome --no-sandbox "$@"\n' > "$MAC_CHROME"
  chmod +x "$MAC_CHROME"
fi

# 4b) Ersteinrichtung pro Projekt: cloud-doctor + Skill projekt-einrichtung ---
# Hooks laufen in Projekt-Threads nicht. Deshalb: Regel im CLAUDE.md-Block,
# ein Skill mit den Fragen und eine Merkdatei im Repo (.claude/projekt-setup.md).
if [ "$WITH_ONBOARDING" = 1 ]; then
step "Ersteinrichtung (cloud-doctor, Skill projekt-einrichtung)"
cat > /usr/local/bin/cloud-doctor <<'EOF'
#!/bin/bash
# cloud-doctor [--quiet] [repo ...]
# Prüft, was ein Projekt in dieser Cloud-VM braucht. Gibt Werte von Variablen nie aus.
# --quiet: nur Fehlendes, eine Zeile pro Befund (für den Start jedes Threads).
quiet=0; [ "${1:-}" = "--quiet" ] && { quiet=1; shift; }
repos=("$@")
if [ ${#repos[@]} = 0 ]; then
  if git rev-parse --show-toplevel >/dev/null 2>&1; then repos=("$(git rev-parse --show-toplevel)")
  else for d in ./*/; do [ -d "$d/.git" ] && repos+=("${d%/}"); done; fi
fi
for i in "${!repos[@]}"; do repos[i]=$(realpath "${repos[i]}"); done
say()  { [ $quiet = 0 ] && echo "$@"; }
miss() { echo "FEHLT: $*"; }

net() { # 0 = erreichbar, 1 = vom Proxy gesperrt
  local c; c=$(curl -s -o /dev/null -m 6 -w '%{http_connect} %{http_code}' "https://$1/" 2>/dev/null)
  case "$c" in 403*|"000 000") return 1;; *) return 0;; esac
}

if [ $quiet = 0 ]; then
  echo "== VM"
  for h in cdn.playwright.dev orvel.undraft.de pkg.ddev.com; do
    if net "$h"; then echo "  Netz $h: erreichbar"; else echo "  Netz $h: gesperrt (Netzwerk Limited?)"; fi
  done
  for s in dockerd:docker mariadbd:mariadb postgres:postgres redis-server:redis; do
    if pgrep -x "${s%%:*}" >/dev/null 2>&1; then echo "  ${s#*:}: läuft"
    else echo "  ${s#*:}: aus (cloud-services ${s#*:})"; fi
  done
  echo "  Repos nebeneinander: $(for d in "$(dirname "$(realpath "${repos[0]:-.}")")"/*/; do [ -d "$d/.git" ] && printf '%s ' "$(basename "$d")"; done)"
fi

for r in "${repos[@]}"; do
  name=$(basename "$r"); cd "$r" || continue
  say ""; say "== $name"
  # Merkdatei der Ersteinrichtung
  if [ -f .claude/projekt-setup.md ]; then say "  Ersteinrichtung: erledigt (.claude/projekt-setup.md)"
  else miss "$name: Ersteinrichtung offen (Skill projekt-einrichtung)"; fi
  # Erwartete Variablen: Liste im Repo plus bekannte Fundstellen
  vars=$( { [ -f .claude/cloud-secrets.txt ] && grep -oE '^[A-Z][A-Z0-9_]+' .claude/cloud-secrets.txt
            git grep -hoIE '\$\{?[A-Z][A-Z0-9_]{3,}\}?' -- '.npmrc' '*/.npmrc' 2>/dev/null | tr -d '${}'
            git grep -qIE 'CENTRAL_LICENSE_KEY|@central-icons' -- 'package.json' '*/package.json' '.npmrc' '*/.npmrc' 2>/dev/null && echo CENTRAL_LICENSE_KEY
          } | sort -u)
  for v in $vars; do
    val="${!v:-}"
    if [ -n "$val" ]; then say "  Variable $v: gesetzt (${#val} Zeichen)"
    else miss "$name: Umgebungsvariable $v nicht gesetzt (Cloud-Umgebung, Environment variables)"; fi
  done
  [ $quiet = 1 ] && continue
  # Was das Projekt mitbringt
  for l in pnpm-lock.yaml package-lock.json yarn.lock bun.lock composer.lock uv.lock; do
    f=$(git ls-files "$l" "*/$l" 2>/dev/null | grep -v node_modules | head -5 | tr '\n' ' ')
    [ -n "$f" ] && echo "  Lockfile $l: $f"
  done
  pw=$(git grep -hoIE "(/playwright|playwright)@[0-9]+\.[0-9]+\.[0-9]+" -- '*pnpm-lock.yaml' '*package-lock.json' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')
  [ -n "$pw" ] && echo "  Playwright im Lockfile: $pw(vorinstalliert: $(npx --no-install playwright --version 2>/dev/null | awk '{print $2}'))"
  [ -d .github/workflows ] && echo "  GitHub-Workflows: $(ls .github/workflows | tr '\n' ' ')(lokal nachstellen, nicht starten)"
  heads=$(git ls-remote --heads origin 2>/dev/null | awk '{sub("refs/heads/","",$2); print $2}')
  def=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#origin/##')
  echo "  Branches: Standard ${def:-?}; $(echo "$heads" | grep -E '^(develop|dev|staging|next|main|master)$' | tr '\n' ' ')"
  mac=$(git ls-files | grep -E '\.xcodeproj/|\.xcworkspace/|(^|/)Package\.swift$|\.entitlements$' | head -3 | tr '\n' ' ')
  [ -n "$mac" ] && echo "  Nur auf dem Mac (Xcode/Signatur): $mac"
  up=$(git grep -lI '/Users/' -- ':!*.lock' ':!*lock.yaml' ':!*lock.json' ':!*.md' ':!*.log' ':!.claude/' 2>/dev/null | head -5 | tr '\n' ' ')
  [ -n "$up" ] && echo "  Feste Mac-Pfade (/Users/...) in: $up"
  sib=$(git grep -hoIE '\.\./(\.\./)*[A-Z][A-Za-z0-9_-]+/' -- ':!*.md' ':!.claude/' 2>/dev/null | sed -E 's#(\.\./)+##; s#/$##' | sort -u)
  for s in $sib; do [ -e "../$s" ] || [ -e "$s" ] || echo "  Verweis auf Nachbarordner ../$s fehlt (Repo anhängen oder Symlink im Setup-Feld)"; done
  for f in CLAUDE.md CONTEXT.md .claude/launch.json .claude/rules .claude/skills; do [ -e "$f" ] && printf '  vorhanden: %s\n' "$f"; done
  if [ -f .claude/settings.json ] && grep -q '"hooks"' .claude/settings.json; then
    echo "  Repo-Hooks in .claude/settings.json: laufen in Projekt-Threads nicht"
  fi
done
exit 0
EOF
chmod +x /usr/local/bin/cloud-doctor

mkdir -p /root/.claude/skills/projekt-einrichtung
cat > /root/.claude/skills/projekt-einrichtung/SKILL.md <<'EOF'
---
name: projekt-einrichtung
description: One-time setup of a project for cloud sessions. Use when the main repo has no .claude/projekt-setup.md, when cloud-doctor reports "Ersteinrichtung offen", or when the user asks to set up a project or environment.
---

# Ersteinrichtung eines Projekts

Läuft einmal pro Repo. Ergebnis ist `.claude/projekt-setup.md` im Repo; solange die Datei da ist, fragt kein
Thread mehr. Mit dem Nutzer in seiner Sprache sprechen.

## 1. Selbst prüfen, bevor gefragt wird

- `cloud-doctor <repo>` ausführen und die Ausgabe auswerten (Netz, fehlende Variablen, Lockfiles, Playwright,
  Workflows, Branches, Mac-only-Teile, feste Mac-Pfade, fehlende Nachbarordner, vorhandene Regeln).
- `CLAUDE.md`, `CONTEXT.md`, `README` und die letzten Commits lesen. Was dort steht, wird nicht gefragt.
- Projekt-Memory lesen. Was dort steht, wird nicht gefragt.
- Wenn möglich die Cloud-Umgebung ansehen (Umgebungs-Tools): Name, Netzwerk, Setup-Feld.

## 2. Einmal fragen, gebündelt

Eine Nachricht, höchstens sieben Fragen, jede mit Antwortmöglichkeiten und Empfehlung. Jede Frage weglassen,
die Schritt 1 oder der Kontext schon beantwortet. Nicht warten: mit den Empfehlungen weiterarbeiten und
Antworten später einarbeiten.

1. Wofür und für wen ist das Projekt (eigenes Produkt, Kundenprojekt, Website, Werkzeug)? Gibt es schon Nutzer?
   (Mit Nutzern gilt für riskante Änderungen die volle Suite.)
2. Wer merged? Empfehlung: Thread merged eigene PRs nach grüner lokaler Prüfung selbst.
3. Was ist ein laufendes Kundensystem oder Produktion? Nur dort, bei endgültigem Datenverlust oder Kosten
   fragt ein Thread vorher; Staging zählt nicht als live.
4. Wie sieht der Nutzer Ergebnisse aus der Cloud? Screenshots im Repo / Staging-URL / Remote Control auf dem Mac.
5. Nur bei UI: Was ist die Vorlage oder das Designsystem, und was wird übernommen (Struktur, Stil, Wirkung)?
6. Nur wenn Orvel eingerichtet ist (`orvel-todo`): In welche Liste kommen To-dos aus diesem Projekt?
7. Nur wenn Schritt 1 Lücken fand: fehlende Repos, Variablen oder Netzwerkfreigaben nennen. Nie nach Werten
   fragen und keine Tokens im Chat annehmen; nur „ist eingetragen“.

Sprache, Berichtsaufbau, Teststufen, Stack und additives Arbeiten nicht fragen: das regeln die Grundregeln.

## 3. Schreiben und selbst erledigen

- `.claude/projekt-setup.md` anlegen (Vorlage unten), dazu `.claude/cloud-secrets.txt` mit den Namen der
  erwarteten Variablen, eine pro Zeile, nie Werte. Committen und pushen nach den Regeln des Repos.
- Setup-Feld der Umgebung passend vorschlagen (`cloud-warm <ordner> [chromium webkit]`, Symlinks für
  Nachbarordner, Schalter wie `WITH_ORVEL=1`). Mit dem Ja des Nutzers selbst eintragen, wenn die
  Umgebungs-Tools verfügbar sind; sonst den fertigen Text liefern.
- Fehlt ein Baustein für die Projekt-Anweisungen, ihn als Datei liefern (gemeinsame Regeln plus Projektteil).
  Eintragen muss der Nutzer selbst.
- Was nur der Nutzer erledigen kann (Variable eintragen, Repo anhängen, Netzwerk umstellen) als To-do in
  Orvel anlegen, wenn eingerichtet; sonst im Bericht unter „Offen für dich“ mit Ort.
- Eine Zeile ins Projekt-Memory: „<repo> eingerichtet am <datum>, siehe .claude/projekt-setup.md“.

## Vorlage `.claude/projekt-setup.md`

```markdown
# Projekt-Setup (Ersteinrichtung <datum>)

Zweck und Nutzer: …
Merge: …
Live und Freigaben: …
Vorschau: …
Vorlage / Designsystem: …
Orvel-Liste: …
Startbranch: …
Nur auf dem Mac: …
Cloud-Umgebung: <name>, Netzwerk <Full|Limited + Hosts>, Setup-Feld siehe unten
Variablen: siehe .claude/cloud-secrets.txt
Offen: …

## Setup-Feld
(Text, wie er in der Umgebung steht)
```

Ändert sich später etwas davon, die Datei direkt anpassen; sie ist die Quelle für spätere Threads.
EOF
fi

# 4c) Vorschau über Tailscale/Headscale (optional) und 1Password-CLI ---------
# cloud-preview <port> macht einen Dev-Server der Session nur für die eigenen
# Geräte im privaten Tailscale-Netz erreichbar (Headscale als Steuerserver).
# Der Schlüssel kommt erst in der Session: aus TS_AUTHKEY oder per op aus dem Vault.
if [ "$WITH_TAILSCALE" = 1 ] || [ "$WITH_1PASSWORD" = 1 ]; then
  step "1Password-CLI (op $OP_VERSION)"
  if ! command -v op >/dev/null; then
    tmp=$(mktemp -d)
    if curl -fsSL -m 60 -o "$tmp/op.zip" "https://cache.agilebits.com/dist/1P/op2/pkg/v$OP_VERSION/op_linux_amd64_v$OP_VERSION.zip" \
       && unzip -qo "$tmp/op.zip" op -d /usr/local/bin; then chmod +x /usr/local/bin/op
    else warn "op nicht installiert (cache.agilebits.com unter Limited gesperrt?)"; fi
    rm -rf "$tmp"
  fi
fi
if [ "$WITH_TAILSCALE" = 1 ]; then
  step "Tailscale (statisch) und cloud-preview"
  if ! command -v tailscaled >/dev/null; then
    v="$TAILSCALE_VERSION"
    [ -z "$v" ] && v=$(curl -fsSL -m 20 'https://pkgs.tailscale.com/stable/?mode=json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["TarballsVersion"])' 2>/dev/null)
    tmp=$(mktemp -d)
    if [ -n "$v" ] && curl -fsSL -m 120 "https://pkgs.tailscale.com/stable/tailscale_${v}_amd64.tgz" | tar xz -C "$tmp"; then
      install -m 755 "$tmp"/tailscale_*/tailscale "$tmp"/tailscale_*/tailscaled /usr/local/bin/
    else warn "Tailscale nicht installiert (pkgs.tailscale.com unter Limited gesperrt?)"; fi
    rm -rf "$tmp"
  fi
  cat > /usr/local/bin/cloud-preview <<'EOF'
#!/bin/bash
# cloud-preview <port> [name]   Port nur im eigenen Tailscale-Netz freigeben
# cloud-preview stop            Freigabe beenden, Gerät abmelden
# cloud-preview status
# Braucht: TS_LOGIN_SERVER (Headscale-Adresse, kein Geheimnis) und einen Schlüssel
# aus TS_AUTHKEY oder per op (OP_SERVICE_ACCOUNT_TOKEN; Eintrag "Headscale Cloud-Schlüssel" im
# Tresor "Cloud Basis" oder ein eigener Verweis in TS_AUTHKEY_REF, nur ASCII).
# Headscale stellt keine HTTPS-Zertifikate aus: Freigabe per http auf Port 80.
set -euo pipefail
SOCK=/run/tailscale.sock; ts() { tailscale --socket="$SOCK" "$@"; }
die() { echo "cloud-preview: $*" >&2; exit 1; }
case "${1:-}" in ""|-h|--help) sed -n '2,6p' "$0"; exit 0 ;; esac
command -v tailscaled >/dev/null || die "Tailscale fehlt (WITH_TAILSCALE=1 im Setup-Feld, Netzwerk Full)"
case "${1:-}" in
  status) ts status 2>/dev/null || echo "nicht verbunden"; ts serve status 2>/dev/null || true; exit 0 ;;
  stop) ts serve reset 2>/dev/null || true; ts logout 2>/dev/null || true
        pkill -x tailscaled 2>/dev/null || true; echo "cloud-preview: beendet"; exit 0 ;;
esac
port="$1"; [[ "$port" =~ ^[0-9]+$ ]] || die "Port als Zahl angeben, z. B. cloud-preview 5173"
[ -n "${TS_LOGIN_SERVER:-}" ] || die "TS_LOGIN_SERVER fehlt (Adresse des Headscale-Servers als Umgebungsvariable). Ohne Headscale gibt es noch keine Vorschau."
if ! pgrep -x tailscaled >/dev/null; then
  nohup tailscaled --tun=userspace-networking --state=mem: --socket="$SOCK" \
    --statedir=/tmp/tailscale >/tmp/tailscaled.log 2>&1 &
  for _ in $(seq 20); do [ -S "$SOCK" ] && break; sleep 0.5; done
fi
if ! ts status >/dev/null 2>&1; then
  key="${TS_AUTHKEY:-}"
  if [ -z "$key" ]; then
    command -v op >/dev/null || die "kein TS_AUTHKEY und keine 1Password-CLI"
    [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "kein TS_AUTHKEY und kein OP_SERVICE_ACCOUNT_TOKEN in der Umgebung"
    # op read lehnt Nicht-ASCII im Verweis ab ("ü"), daher Standard per Name über op item get.
    if [ -n "${TS_AUTHKEY_REF:-}" ]; then
      key=$(op read "$TS_AUTHKEY_REF" 2>/dev/null) || die "Schlüssel nicht lesbar ($TS_AUTHKEY_REF)"
    else
      key=$(op item get "Headscale Cloud-Schlüssel" --vault "Cloud Basis" --fields credential --reveal 2>/dev/null) \
        || die "Schlüssel nicht lesbar (Tresor \"Cloud Basis\", Eintrag \"Headscale Cloud-Schlüssel\")"
    fi
  fi
  repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
  name="${2:-cloud-$repo-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  # Kein --advertise-tags: der Schlüssel bringt tag:cloud mit, Headscale lehnt zusätzliche Tags ab.
  ts up --reset --login-server="$TS_LOGIN_SERVER" --authkey="$key" --hostname="$name" \
     --accept-dns=false >/dev/null || die "Anmeldung fehlgeschlagen, Log: /tmp/tailscaled.log"
  unset key
fi
ts serve reset >/dev/null 2>&1 || true
ts serve --bg --http=80 "$port" >/dev/null || die "Freigabe fehlgeschlagen, Log: /tmp/tailscaled.log"
# serve antwortet nur auf den Gerätenamen, die 100.64.x.x-IP liefert 404.
host=$(ts status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
echo "cloud-preview: http://$host (Port $port, nur aus deinem Tailscale-Netz)"
EOF
  chmod +x /usr/local/bin/cloud-preview
fi

# 4d) Such-Helfer Explore auf einem günstigen Modell -------------------------
# Der eingebaute Explore-Agent läuft sonst auf dem Hauptmodell. Eine Datei gleichen
# Namens in ~/.claude/agents ersetzt ihn (getestet: läuft dann auf haiku).
if [ -n "$EXPLORE_MODEL" ]; then
  mkdir -p /root/.claude/agents
  cat > /root/.claude/agents/Explore.md <<EOF
---
name: Explore
description: Read-only search agent for broad fan-out searches across many files, directories or naming conventions when only the conclusion is needed. Locates code and facts; does not review or audit. Specify breadth ("medium" or "very thorough").
model: $EXPLORE_MODEL
tools: Read, Grep, Glob, Bash
---

You are a fast, read-only search agent. Find what the caller asks for and report the conclusion with file paths and
line numbers. Read excerpts, not whole files. Never edit, write, commit or run commands that change state; use Bash
only for read-only commands (ls, rg, git log, git show, cat, head). Keep the report short: answer first, then the
evidence (path:line), then what you could not find.
EOF
else
  rm -f /root/.claude/agents/Explore.md
fi

# 5) Persönliche Hinweise für Claude (~/.claude/CLAUDE.md) --------------------
step "/root/.claude/CLAUDE.md schreiben"
mkdir -p /root/.claude
# Eigenen Block bei jedem Lauf ersetzen, Rest der Datei unangetastet lassen
touch /root/.claude/CLAUDE.md
sed -i '/<!-- cloud-setup:begin -->/,/<!-- cloud-setup:end -->/d' /root/.claude/CLAUDE.md
cat >> /root/.claude/CLAUDE.md <<'EOF'
<!-- cloud-setup:begin -->
# Cloud-VM (vom Setup-Skript eingerichtet)
- Dienste laufen nach Sessionstart NICHT. Bei Bedarf: `cloud-services docker|mariadb|postgres|redis|all`.
  MariaDB/Postgres: lokal als root ohne Passwort erreichbar (`mysql`, `sudo -u postgres psql`).
- Docker-Container haben ohne Proxy kein Internet. Für Netz im Container `docker-run-proxied ...`
  verwenden bzw. in compose `network_mode: host` + HTTPS_PROXY + CA-Mount (/root/.ccr/ca-bundle.crt).
- Projekt-Threads führen KEINE Hooks aus `.claude/settings.json` aus. Vor dem ersten Build/Test im
  Projektordner `cloud-install <ordner>` ausführen (installiert mit Lockfile, merkt sich den Stand).
  Hat ein Repo eigene Start-Hooks (z. B. `.claude/hooks/*.sh`), diese bei Bedarf selbst ausführen.
- Composer als root: `COMPOSER_ALLOW_SUPERUSER=1` muss gesetzt sein, sonst sind Plugins aus
  (TYPO3-Installer!). Ist in ~/.bashrc gesetzt; falls nicht, voranstellen.
- Der macOS-Chrome-Pfad `/Applications/Google Chrome.app/...` existiert hier als Wrapper auf
  /usr/bin/google-chrome, Skripte mit festem Mac-Pfad laufen also unverändert.
- Browser-Tests: `agent-browser` (siehe Skill agent-browser), Playwright ist ebenfalls vorinstalliert.
- GitHub: `gh` funktioniert nur mit REST für angehängte Repos (`gh api repos/<owner>/<repo>/...`);
  `gh pr`/`gh issue` (GraphQL) sind gesperrt, dafür die eingebauten GitHub-Tools nutzen.
- Andere Node-Versionen: /opt/node20/bin bzw. /opt/node21/bin vor PATH setzen.
- Log des Setups: /var/log/cloud-setup.log
- Vorschau für den Nutzer (nur wenn `cloud-preview` installiert ist): Dev-Server starten, dann
  `cloud-preview <port>`; die Adresse ist nur aus seinem Tailscale-Netz erreichbar. Beim ersten Mal
  in einem Projekt sein ausdrückliches Ja abwarten. Am Ende `cloud-preview stop`.
<!-- cloud-setup:end -->
EOF
if [ "$WITH_ONBOARDING" = 1 ]; then
  python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
rule = """- Ersteinrichtung: Zu Beginn jedes Threads `cloud-doctor --quiet` im Hauptrepo ausführen. Meldet es
  „Ersteinrichtung offen“, einmal den Skill `projekt-einrichtung` laden und das Projekt einrichten
  (erst selbst prüfen, dann höchstens sieben gebündelte Fragen, Antworten nach `.claude/projekt-setup.md`).
  Ist die Datei da, nichts fragen; fehlende Variablen nur in einer Zeile melden und weiterarbeiten.
"""
s = s.replace("<!-- cloud-setup:end -->", rule + "<!-- cloud-setup:end -->", 1)
open(p, "w").write(s)
PY
fi
{
  [ "$WITH_CF_CLI" = 1 ] && printf '%s\n' '- Cloudflare: `cf` (Beta) für die ganze API; Befehle mit `cf cli search "<aufgabe>"` finden.' \
    '  Token als `CLOUDFLARE_API_TOKEN` aus der Umgebung, nie im Befehl.'
  [ "$WITH_EMULATE" = 1 ] && printf '%s\n' '- `emulate` (vercel-labs): lokale Stellvertreter für GitHub, Resend, S3, Stripe u. a.' \
    '  (`emulate list`, `emulate start`). Für Tests von Mails und Abläufen statt echter Konten.'
  [ "$WITH_REACT_DOCTOR" = 1 ] && printf '%s\n' '- React-Projekte: vor Abschluss `react-doctor <app> --no-telemetry --no-supply-chain -y`;' \
    '  Funde zum geänderten Code beheben. Ohne die zwei Schalter schickt es Daten nach außen.'
} > /tmp/cloud-setup-tools.md
python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
add = open("/tmp/cloud-setup-tools.md").read()
s = s.replace("<!-- cloud-setup:end -->", add + "<!-- cloud-setup:end -->", 1) if add else s
open(p, "w").write(s)
PY
rm -f /tmp/cloud-setup-tools.md
if [ "$WITH_RULES" = 1 ]; then
  python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
rule = """
## Grundregeln (gelten in jeder Session; Vorgaben des Nutzers und des Repos gehen vor)

Stack
- Webprojekte mit Tailwind CSS. Wo React sinnvoll ist: shadcn/ui auf Tailwind, Standardkomponenten
  aus shadcn und seinen Registries statt selbst gebauter Grundkomponenten.
- Mit Tailwind immer `@shadcn/lint` (npm) einrichten und vor Abschluss laufen lassen.
- CMS für Kundenprojekte: Neue Projekte eher mit TYPO3 (Seitenbaum), langfristige Richtung des
  Nutzers. Bestehende Payload-Projekte bleiben auf Payload und werden normal weiter gepflegt.

Design
- Kein Styling ohne benannte Vorlage; fehlt sie, zuerst danach fragen.
- Bei Design- und UI-Arbeit die passenden Design-Skills laden: `apple-design`, `emil-design-eng`
  und die `better-*`-Familie (`better-interface` für den Gesamtblick).
- Der Taste-Skill (`design-taste-frontend`) lädt nur auf Zuruf (`/design-taste-frontend`) und gilt dann als Anregung, nie als Vorschrift.
  Bei Widerspruch gehen die anderen Skills, die Projektvorgaben und Vorlagen des Nutzers vor.

Arbeitsweise
- Rangfolge bei Widerspruch: Auftrag des Nutzers, dann CLAUDE.md und Regeln des Repos, dann diese
  Grundregeln, dann Skills und Playbooks.
- Korrekturen so eng umsetzen, wie sie gesagt wurden. Feedback zu einer Arbeit wird keine allgemeine
  Regel, außer der Nutzer sagt es. Nur ändern, was verlangt ist; anderes im Bericht unter
  „Außerdem geändert“ nennen.
- Selbst handeln statt fragen (Wunsch des Nutzers): eigene PRs nach grüner lokaler Prüfung selbst
  mergen, Befehle selbst ausführen. Rückfragen nur, wenn etwas Daten endgültig löscht, ein laufendes
  Kundensystem trifft, Geld kostet oder ein neues Konto braucht; dann in einfacher Sprache mit Empfehlung.
- Mit dem Nutzer: Ergebnis zuerst, kurz, keine Fachbegriffe ohne Grund. Was nur er tun kann, auf
  einen Schritt mit genauer Stelle reduzieren, keine Anleitungen mit vielen Schritten. Code,
  Bezeichner, Kommentare und Commits auf Englisch.
- Geheimnisse: Werte nie ausgeben, nie in Dateien, Commits oder Chats; nichts Geheimes in öffentliche Repos.
- Voller Umfang ist Standard: offene Punkte erledigen statt auflisten.
- Keine neuen Freigabe-Regeln („nur mit Ja des Nutzers“) in Repos oder Anweisungen schreiben, die der
  Nutzer nicht selbst so gesagt hat.
- Vor jedem Anlegen (Repo, Ordner, Version, Datei, Umgebung) nach Vorhandenem suchen und es nennen.
- Stand am Ende jedes Threads in `CONTEXT.md` des Repos; nichts außerhalb von Repo oder Project-Memory ablegen.
- Texte: eigener Durchgang vor dem Abschluss; keine Antithesen, Aphorismen, Personifizierungen, erfundenen Namen.
- Abschlussbericht in dieser Reihenfolge: Offen für dich · Ergebnis · Außerdem geändert · Entschieden ·
  Nicht geprüft.
- Langes Feedback (Diktat, viele Punkte) zuerst als nummerierte Liste ins Repo schreiben
  (`feedback/<datum>.md`) und am Ende jeden Punkt abhaken.
- Fertig erst mit Beleg: UI mit eigenem Screenshot der laufenden Arbeit (in der Cloud per
  `agent-browser`), neben der Vorlage, wenn es eine gibt.
- Im Abschluss je genutztem Skill eine Zeile, was er konkret verändert hat. Ohne diese Zeile gilt er
  als nicht benutzt.
- Im Abschluss nennen, was im Hintergrund noch läuft und wem es gehört.

Additiv statt destruktiv
- Größere Iterationen (neues Design, neues Konzept, Umbau) als neue Version anlegen (Ordner oder
  Branch/Commit); die vorige bleibt unverändert und lauffähig. Nichts löschen oder überschreiben,
  was nicht ausdrücklich ersetzt werden soll.
- Kleine Änderungen (Texte, einzelne Werte, Fehlerkorrekturen) direkt ändern; Git versioniert.

Tests nach Gewicht der Änderung
- Vor dem Start einordnen und den Prüfumfang danach wählen:
  - Klein (wenige Zeilen, Text, Konfiguration, kein neues Verhalten): höchstens der eine Check,
    der die Stelle trifft, oft reichen Lint und Typecheck.
  - Mittel (ein Feature, ein Fehler, ein Modul): nur die Tests des betroffenen Pakets oder der
    betroffenen Specs (z. B. `pnpm --filter <paket> test`, `vitest run <pfad>`, `playwright test <spec>`).
  - Groß (gemeinsame Mechanik, Datenmodell, Sicherheit, Deployment, Release) oder ein laufendes
    Produkt mit Nutzern: volle Suite.
- Die volle Suite höchstens einmal am Ende eines Arbeitsschritts, nicht nach jeder Einheit. Befunde
  gesammelt beheben, dann ein neuer Lauf.
- Diese Stufen gehen Vorgaben aus Skills und Playbooks vor (z. B. pstack „verify after every unit“):
  gemeint ist dort der gezielte, billige Check, nicht die volle Suite.
- Lange Läufe im Hintergrund mit Log-Datei, nur deren Ende lesen.
"""
s = s.replace("<!-- cloud-setup:end -->", rule + "<!-- cloud-setup:end -->", 1)
open(p, "w").write(s)
PY
fi
if [ "$LOCAL_CI" = 1 ]; then
  # Regel in den Block einfügen (vor dem End-Marker)
  python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
rule = """- CI läuft hier in der VM, nicht auf GitHub (Actions-Minuten sind knapp):
  Lint, Typecheck, Tests, Builds und Playwright in der Session ausführen, bevor gepusht wird.
  Hat das Repo `.github/workflows/`, deren `run:`-Schritte lokal nachstellen (Dienste per
  `cloud-services` oder `docker run`). Keine neuen Workflows anlegen, keine Workflows per
  `workflow_dispatch` oder Re-Run starten und nicht auf Actions-Ergebnisse warten, außer der
  Nutzer verlangt es ausdrücklich oder es geht nachweislich nur dort (z. B. andere Plattform).
  Im Bericht nennen, was lokal geprüft wurde.
"""
s = s.replace("<!-- cloud-setup:end -->", rule + "<!-- cloud-setup:end -->", 1)
open(p, "w").write(s)
PY
fi

# 5b) Gemeinsames Wissen in einem privaten Repo (WISSEN_REPO, muss am Project hängen) -

if [ "$WITH_WISSEN" = 1 ]; then
  python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
rule = """
## Gemeinsames Wissen (Repo __WREPO__)
- Liegt `__WDIR__/wissen/INDEX.md` neben den Repos (meist `/home/user/__WDIR__`), dort nachschlagen, bevor du den Nutzer
  etwas über Arbeitsweise, Stack, Projekte oder Vorgehen fragst oder neu recherchierst: Index lesen (2 KB),
  dem Pfad folgen, eine Datei lesen. Nie den ganzen Ordner laden. Skill `wissen` erklärt Lesen und Pflegen.
- Was du lernst und was über dein Project hinaus gilt, trägst du am Ende der Aufgabe dort ein (PR, selbst mergen).
- Worte des Nutzers und die Repo-Regeln gehen vor. Fehlt das Repo, ohne es weiterarbeiten.
"""
s = s.replace("<!-- cloud-setup:end -->", rule + "<!-- cloud-setup:end -->", 1)
open(p, "w").write(s)
PY
  mkdir -p /root/.claude/skills/wissen
  cat > /root/.claude/skills/wissen/SKILL.md <<'EOF'
---
name: wissen
description: Look up or update the user's shared knowledge in the __WDIR__ repo (wissen/). Use before asking the user about their way of working, stack, projects or procedures, and at the end of a task when you learned something that holds beyond this project.
---

# Gemeinsames Wissen (__WREPO__)

Das Repo liegt neben den anderen Repos der Session (meist `/home/user/__WDIR__`, auf dem Mac `~/dev/__WDIR__`).
Fehlt es, hängt es nicht am Project: in einer Zeile erwähnen und ohne weiterarbeiten.

## Lesen (wenige Tokens)

1. `__WDIR__/wissen/INDEX.md` lesen. Eine Zeile pro Frage, mit Pfad.
2. Nur die eine Datei lesen, auf die der Pfad zeigt (höchstens 4 KB). Hat ein Ordner eine `INDEX.md`, zuerst die.
3. Passt nichts: `rg -il "<begriff>" __WDIR__/wissen` und gezielt lesen. Nie den ganzen Ordner laden.

Wissen hier ist Hintergrund. Die Worte des Nutzers im Thread und die Regeln des Repos gehen vor.
Widerspricht eine Datei dem, was du gerade sicher feststellst, korrigiere die Datei (siehe unten).

## Pflegen (der Nutzer pflegt es nicht, die Sessions tun es)

Eintragen am Ende einer Aufgabe, wenn du etwas gelernt hast, das über dieses Project hinaus gilt:
eine abstrakte Korrektur des Nutzers, ein geprüfter Fakt über Werkzeuge, Umgebung oder Dienste, ein neues
oder umbenanntes Projekt, ein geänderter Stack, eine Lektion aus einem Fehler. Projektinternes bleibt im Projekt.

1. Passende Datei über den Index finden und dort ändern. Veraltetes ersetzen oder löschen, nicht anhängen.
2. Erste Zeile `Stand: JJJJ-MM-TT` auf heute setzen. Fakten mit Quelle (Thread, PR, Datei) und Datum.
3. Höchstens 4 KB pro Datei; sonst Ordner mit eigener `INDEX.md`. Neue Datei im übergeordneten Index eintragen,
   `wissen/INDEX.md` bleibt unter 2 KB.
4. `bash __WDIR__/scripts/check.sh` ausführen, bis es `ok` meldet.
5. Branch, Commit, PR gegen `main`, selbst mergen. Im Bericht eine Zeile: was du in __WDIR__ geändert hast.

Nie eintragen: Passwörter, Tokens, Schlüssel, Konto-IDs oder andere Zugangswerte (nur wo etwas liegt);
Kundendaten, Vertrauliches, Privates. Meldet `check.sh` einen Stand über 120 Tage in einer Datei, die du nutzt:
prüfen, korrigieren, Stand neu setzen.

## Postfach

Braucht ein anderes Project etwas von dir oder du von ihm: Issue in __WREPO__ mit Label `an:<project>`
(siehe `__WDIR__/postfach/README.md`). In der Cloud gehen `gh issue` und `gh pr` nicht; die GitHub-Werkzeuge der Session nutzen.
EOF
  # Repo-Namen einsetzen (konfigurierbar über WISSEN_REPO)
  wdir=$(basename "$WISSEN_REPO")
  # Persönliche gemeinsame Anweisungen aus dem privaten Repo (liegt beim Bau schon geklont daneben)
  if [ -f "./$wdir/$SHARED_RULES" ]; then
    { echo; echo "## Gemeinsame Anweisungen (aus $WISSEN_REPO/$SHARED_RULES; ist die Datei neuer, gilt sie)"
      sed '1{/^Stand:/d}; /^# /d; s/^## /### /' "./$wdir/$SHARED_RULES"; } > /tmp/cloud-setup-shared.md
    python3 - <<'PY'
p = "/root/.claude/CLAUDE.md"
s = open(p).read()
s = s.replace("<!-- cloud-setup:end -->", open("/tmp/cloud-setup-shared.md").read() + "<!-- cloud-setup:end -->", 1)
open(p, "w").write(s)
PY
    rm -f /tmp/cloud-setup-shared.md
    echo "  gemeinsame Anweisungen aus $wdir/$SHARED_RULES übernommen"
  else
    warn "$wdir/$SHARED_RULES nicht gefunden (Repo $WISSEN_REPO nicht am Project?)"
  fi
  sed -i "s#__WREPO__#$WISSEN_REPO#g; s#__WDIR__#$wdir#g" /root/.claude/CLAUDE.md /root/.claude/skills/wissen/SKILL.md
fi

# 6) Projekt-Hooks aus den Repos ----------------------------------------------
# Das Setup-Skript startet im Verzeichnis über den geklonten Repos.
if [ "$WITH_REPO_HOOKS" = 1 ]; then
  step "Projekt-Hooks suchen"
  for hook in ./*/.claude/cloud-setup.sh; do
    [ -f "$hook" ] || continue
    echo ">> $hook"
    ( cd "$(dirname "$hook")/.." && timeout 180 bash .claude/cloud-setup.sh ) || warn "Hook $hook fehlgeschlagen"
  done
fi

# 7) PROJEKTSPEZIFISCH ----------------------------------------------------------
# Hier eigene Schritte für diese Umgebung eintragen. Das Skript steht im
# Verzeichnis ÜBER den geklonten Repos, also erst in das Repo wechseln.
# Fehler mit "|| true" abfangen, damit die Session trotzdem startet.
step "Projektspezifische Schritte"
#
# TYPO3 / Shopware (PHP):
#   (cd mein-repo && composer install --no-progress --prefer-dist) || true
# Node / Next.js (Lockfile bestimmt den Paketmanager):
#   (cd mein-repo && pnpm install --frozen-lockfile) || true
#   (cd mein-repo && npm ci --no-audit --no-fund) || true
# Abhängigkeiten vorab in den Cache laden, ohne Install-Skripte (Lizenz-Keys u. ä.
# sind hier noch nicht da); in der Session dann `cloud-install <ordner>`:
#   cloud-warm mein-repo chromium        # optional: Playwright-Browser passend zum Lockfile
# Docker-Images vorab ziehen (landen im Cache-Snapshot):
#   cloud-services docker && (cd mein-repo && docker compose pull -q) || true
# Datenbank für ein Projekt anlegen (MariaDB nach Gebrauch wieder stoppen):
#   cloud-services mariadb && mysql -e "CREATE DATABASE IF NOT EXISTS app" ; service mariadb stop || true
#
# Alternative ohne Eintrag hier: Datei <repo>/.claude/cloud-setup.sh ins Repo
# legen, sie läuft oben unter "Projekt-Hooks" automatisch mit.

# 8) Zusammenfassung ----------------------------------------------------------
step "Fertig"
for t in node php composer python3 uv go cargo docker psql mysql redis-server gh agent-browser vercel fd fzf shellcheck sqlite3 op tailscale cf emulate react-doctor cloud-services cloud-warm cloud-install cloud-doctor cloud-preview; do
  printf "  %-14s %s\n" "$t" "$(command -v $t >/dev/null && echo ok || echo -)"
done
printf "  skills:"; for d in /root/.claude/skills/*/; do d=$(basename "$d"); case $d in synced|session-start-hook) ;; *) printf " %s" "$d";; esac; done; echo
DUR=$(( $(date +%s) - START ))
echo "== cloud-setup fertig in ${DUR}s =="
[ "$DUR" -gt 270 ] && warn "Setup dauert ${DUR}s, ab ~300s wird die Umgebung nicht mehr gecacht"
exit 0
