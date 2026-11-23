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

# 5) Persönliche Hinweise für Claude (~/.claude/CLAUDE.md) --------------------
step "/root/.claude/CLAUDE.md schreiben"
mkdir -p /root/.claude
MARK="<!-- cloud-setup:begin -->"
if ! grep -q "$MARK" /root/.claude/CLAUDE.md 2>/dev/null; then
cat >> /root/.claude/CLAUDE.md <<'EOF'
<!-- cloud-setup:begin -->
# Cloud-VM (vom Setup-Skript eingerichtet)
- Dienste laufen nach Sessionstart NICHT. Bei Bedarf: `cloud-services docker|mariadb|postgres|redis|all`.
  MariaDB/Postgres: lokal als root ohne Passwort erreichbar (`mysql`, `sudo -u postgres psql`).
- Docker-Container haben ohne Proxy kein Internet. Für Netz im Container `docker-run-proxied ...`
  verwenden bzw. in compose `network_mode: host` + HTTPS_PROXY + CA-Mount (/root/.ccr/ca-bundle.crt).
- Composer als root: `COMPOSER_ALLOW_SUPERUSER=1` muss gesetzt sein, sonst sind Plugins aus
  (TYPO3-Installer!). Ist in ~/.bashrc gesetzt; falls nicht, voranstellen.
- Browser-Tests: `agent-browser` (siehe Skill agent-browser), Playwright ist ebenfalls vorinstalliert.
- GitHub: `gh` funktioniert nur mit REST für angehängte Repos (`gh api repos/<owner>/<repo>/...`);
  `gh pr`/`gh issue` (GraphQL) sind gesperrt, dafür die eingebauten GitHub-Tools nutzen.
- Andere Node-Versionen: /opt/node20/bin bzw. /opt/node21/bin vor PATH setzen.
- Log des Setups: /var/log/cloud-setup.log
<!-- cloud-setup:end -->
EOF
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
# Docker-Images vorab ziehen (landen im Cache-Snapshot):
#   cloud-services docker && (cd mein-repo && docker compose pull -q) || true
# Datenbank für ein Projekt anlegen (MariaDB nach Gebrauch wieder stoppen):
#   cloud-services mariadb && mysql -e "CREATE DATABASE IF NOT EXISTS app" ; service mariadb stop || true
#
# Alternative ohne Eintrag hier: Datei <repo>/.claude/cloud-setup.sh ins Repo
# legen, sie läuft oben unter "Projekt-Hooks" automatisch mit.

# 8) Zusammenfassung ----------------------------------------------------------
step "Fertig"
for t in node php composer python3 uv go cargo docker psql mysql redis-server gh agent-browser vercel fd fzf shellcheck sqlite3; do
  printf "  %-14s %s\n" "$t" "$(command -v $t >/dev/null && echo ok || echo -)"
done
printf "  skills:"; for d in /root/.claude/skills/*/; do d=$(basename "$d"); case $d in synced|session-start-hook) ;; *) printf " %s" "$d";; esac; done; echo
DUR=$(( $(date +%s) - START ))
echo "== cloud-setup fertig in ${DUR}s =="
[ "$DUR" -gt 270 ] && warn "Setup dauert ${DUR}s, ab ~300s wird die Umgebung nicht mehr gecacht"
exit 0
