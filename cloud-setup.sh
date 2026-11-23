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
: "${WITH_SKILLS:=1}"         # Skills aus GitHub nach ~/.claude/skills holen
: "${WITH_REPO_HOOKS:=1}"     # <repo>/.claude/cloud-setup.sh jedes Repos ausführen

# Zusätzliche apt-Pakete (Leerzeichen-getrennt)
APT_EXTRA="${APT_EXTRA:-}"
# Zusätzliche globale npm-Pakete
NPM_EXTRA="${NPM_EXTRA:-}"

# Orvel-Aufgaben-App (siehe Abschnitt 3b); URL des CLI-Downloads ohne Dateiname
: "${WITH_ORVEL:=0}"
: "${ORVEL_CLI_URL:=}"

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
SKILL_SOURCES="${SKILL_SOURCES:-vercel-labs/agent-skills:web-design-guidelines emilkowalski/skills:emil-design-eng}"
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
   (by name). Do not create lists. If none fits clearly, take the list whose name is closest to the topic and say
   which one you picked in your reply.
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
Only use `orvel-todo add` and `orvel-todo lists`: do not move, change or complete the user's tasks.
EOF
fi

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
# Nutzung: cloud-warm <projektordner> [browser ...]   z. B. cloud-warm brand-canvas chromium webkit
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
<!-- cloud-setup:end -->
EOF

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
for t in node php composer python3 uv go cargo docker psql mysql redis-server gh agent-browser vercel fd fzf shellcheck sqlite3 cloud-services cloud-warm cloud-install; do
  printf "  %-14s %s\n" "$t" "$(command -v $t >/dev/null && echo ok || echo -)"
done
printf "  skills:"; for d in /root/.claude/skills/*/; do d=$(basename "$d"); case $d in synced|session-start-hook) ;; *) printf " %s" "$d";; esac; done; echo
DUR=$(( $(date +%s) - START ))
echo "== cloud-setup fertig in ${DUR}s =="
[ "$DUR" -gt 270 ] && warn "Setup dauert ${DUR}s, ab ~300s wird die Umgebung nicht mehr gecacht"
exit 0
