# Cloud-Setup für Claude-Code-Sessions

Gemeinsame Basis für alle Cloud-Umgebungen, pro Projekt erweiterbar.
Alles hier wurde am 23.11.2026 in einer echten Cloud-Session getestet
(Umgebung „Default“, Netzwerk *Limited* + Paketmanager; die neue Umgebung mit
*Full* erlaubt zusätzlich beliebige Hosts).

**Eine Datei:** `cloud-setup.sh`, in sich geschlossen (Helfer `cloud-services` und `docker-run-proxied`
sind eingebettet). `example-repo-hook.sh` ist nur eine optionale Vorlage für `<repo>/.claude/cloud-setup.sh`.

**Gemessen:** kalter Lauf 31 s, Folge-Läufe 4–7 s. Grenze für den Cache-Snapshot: ca. 5 Minuten.

## Was die VM mitbringt (getestet)

Ubuntu 24.04, **root**, 4 vCPU, 16 GB RAM, ~30 GB Disk-Kontingent (`df` zeigt mehr, ist irreführend).

- **Vorinstalliert:** Node 22 (20/21 unter `/opt/node2x`), npm, pnpm, yarn, bun, Python 3.13 + uv + poetry,
  PHP 8.3 + Composer (inkl. intl, gd, pdo_mysql, redis, zip …), Go 1.24, Rust 1.97, Java 21 + Maven/Gradle,
  Ruby 3.3, gcc/clang/cmake, Docker 29 + Compose, PostgreSQL 16, Redis 7, Chrome + Playwright, ffmpeg,
  ImageMagick, gh, jq, yq, ripgrep.
- **Fehlt:** MySQL/MariaDB, sqlite3-CLI, fd, fzf, shellcheck, Vercel CLI, .NET, Deno, DDEV → `cloud-setup.sh` ergänzt das Wichtigste.
- **apt, npm -g, pip, composer, cargo, go** funktionieren. bun install lief trotz Doku-Warnung problemlos.

## Grenzen und Stolpersteine

1. **Nichts läuft nach dem Start.** Snapshot = nur Dateien. Docker-Daemon, MariaDB, Postgres, Redis müssen pro
   Session gestartet werden → `cloud-services all` (installiert `cloud-setup.sh`).
2. **Docker-Container haben kein Internet**, außer über den Session-Proxy mit `--network host` + Proxy-Variablen +
   CA-Zertifikat → Wrapper `docker-run-proxied`. Images ziehen klappt normal.
3. **Composer als root schaltet Plugins ab** → TYPO3-Installer bricht still. `cloud-setup.sh` setzt
   `COMPOSER_ALLOW_SUPERUSER=1`. Damit lief `composer create-project typo3/cms-base-distribution` (v13.4) in 1:53 min.
4. **GitHub nur für angehängte Repos.** Fremde private Repos sind nicht klonbar, öffentliche schon (git clone,
   Release-Downloads, raw.githubusercontent.com). `gh pr` / `gh issue` (GraphQL) sind gesperrt; `gh api repos/...` geht.
5. **In Projekt-Threads laufen keine Hooks aus `.claude/settings.json`**, auch kein `.mcp.json` und kein `env`.
   Deshalb gehört Projekt-Setup in das Setup-Skript bzw. in `<repo>/.claude/cloud-setup.sh` (wird vom Basis-Skript ausgeführt).
6. **Setup-Skript sieht die Umgebungsvariablen noch nicht** und muss Exit 0 liefern. Secrets nie ins Skript;
   API-Keys als „Network secrets“ der Umgebung.
7. **Cache-Neubau** nur bei Änderung des Skripttexts, der Netzwerkregeln oder nach ~7 Tagen.
8. **Befehlslaufzeit:** 2 min Standard, max. 10 min im Vordergrund. Für lange Builds Umgebungsvariablen
   `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS` setzen.
9. **DDEV** nicht live getestet (Download klappt, Ausführung wurde hier blockiert). DDEV ist nicht für root gedacht
   und braucht viele Images. Empfehlung: in der Cloud direkt mit PHP + MariaDB + Composer arbeiten; DDEV lokal behalten.

## Tools von vercel-labs: Einschätzung

| Tool | Urteil | Warum |
|---|---|---|
| **agent-browser** | **Ja, in der Basis** | Läuft sofort mit dem vorinstallierten Chrome: Seite öffnen, Accessibility-Snapshot mit Refs, klicken, Screenshot. Getestet gegen einen lokalen Server. Ideal zum Prüfen von Frontends in der Cloud. |
| **skills** (`npx skills`) | Ja, lokal | CLI zum Installieren von Skills; in der Cloud übernimmt `cloud-setup.sh` das direkt per git (schneller, ohne Interaktion). |
| **agent-skills** | Teilweise | `web-design-guidelines` in der Basis; `react-best-practices`/`composition-patterns` nur für React/Next-Projekte. |
| **portless** | Optional | Stabile `name.localhost`-URLs, glänzt bei parallelen Worktrees lokal. In der Cloud (eine VM pro Session) wenig Nutzen. |
| **opensrc** | Später | Quellcode von Paketen für den Agenten holen; braucht Node 24, VM hat 22. |
| **deepsec** | Prüfen | Security-Scanning, eher als eigener Schritt/CI als im Basis-Setup. |
| Vercel CLI | Schalter | `WITH_VERCEL_CLI=1` nur in Umgebungen mit Vercel-Deployments (Token als Network secret). |

## Skills: wie sie in die Cloud kommen

Drei Wege, alle bestätigt:

1. **claude.ai-Account** (claude.ai/customize/skills): werden in jede Cloud-Session synchronisiert. Richtig für
   **eigene** Skills, die überall gelten sollen. Funktioniert auch mit privaten Inhalten.
2. **Repo** `.claude/skills/`: richtig für projektspezifische Skills; Projekt-Threads laden sie mit.
3. **Setup-Skript → `~/.claude/skills/`** (Block KONFIGURATION, `SKILL_SOURCES`): richtig für **öffentliche Fremd-Skills**. Getestet: Claude Code lädt dort
   abgelegte Skills sofort.

Empfehlung: Basis klein halten (jede Skill-Beschreibung kostet in jeder Session Kontext). Standard in `cloud-setup.sh`:
`agent-browser`, `web-design-guidelines`, `emil-design-eng`. Pro Umgebung per `SKILL_SOURCES` erweitern. Kandidaten
aus der Link Library (hoch bewertet, alle getestet klonbar): `emilkowalski/skills`, `mattpocock/skills`,
`humanlayer/skills`, pstack (`cursor/plugins` → `pstack/skills`, Skills hängen voneinander ab, besser als Plugin).

## Helfer, die das Skript installiert

| Befehl | Wofür |
|---|---|
| `cloud-services docker\|mariadb\|postgres\|redis\|all` | Dienste pro Session starten (laufen nach dem Start nie) |
| `docker-run-proxied …` | `docker run` mit Internet über den Session-Proxy |
| `cloud-warm <ordner> [chromium webkit]` | **Im Setup-Feld:** Paket-Cache (pnpm/npm/composer/uv) und passende Playwright-Browser vorab in den Snapshot laden, ohne Install-Skripte |
| `cloud-install <ordner>` | **In der Session:** Abhängigkeiten installieren, wenn Umgebungsvariablen (z. B. Lizenz-Keys) da sind; überspringt, wenn das Lockfile unverändert ist |
| `/Applications/Google Chrome.app/…` | Wrapper auf das Linux-Chrome mit `--no-sandbox`, damit Skripte mit festem macOS-Pfad laufen |

Warum zwei Schritte: Das Setup-Skript sieht die Umgebungsvariablen der Umgebung noch nicht. Pakete mit Lizenzprüfung im
Install-Skript (z. B. Central Icons) scheitern dort. `cloud-warm` lädt alles vorab, `cloud-install` installiert dann in
Sekunden aus dem Cache. Projekt-Threads führen keine Repo-Hooks aus, deshalb steht der Hinweis auf `cloud-install` in
`~/.claude/CLAUDE.md`.

Playwright lädt Browser von `cdn.playwright.dev`. Das ist im Netzwerk-Level *Limited* nicht freigegeben: entweder *Full*
nutzen oder die Domain unter „Allowed domains“ eintragen.

## Orvel (optional)

`WITH_ORVEL=1 ORVEL_CLI_URL=<basis-url> bash <(curl …)` installiert die Orvel-CLI (mit SHA-256-Prüfung), den Wrapper
`orvel-todo` und den Skill `orvel-todo`. Sessions legen damit Aufgaben an, die nur der Nutzer selbst erledigen kann.
Die Umgebung braucht dafür die Variable `ORVEL_AGENT_CREDENTIAL`. Fehlt Binary oder Credential, bricht nichts ab.

## Einbinden

Ins Feld **Setup script** der Cloud-Umgebung (claude.ai/code → Project settings → Environment → Zahnrad der Umgebung):

```bash
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/builtui/cloud-setup/main/cloud-setup.sh)

# Zusätze nur für diese Umgebung, z. B.:
# (cd mein-repo && composer install --no-progress) || true
exit 0
```

Schalter pro Umgebung vor `bash` setzen, z. B. `WITH_MARIADB=0 WITH_VERCEL_CLI=1 bash <(curl ...)`, oder zusätzliche Skills mit
`SKILL_SOURCES="vercel-labs/agent-skills:web-design-guidelines mattpocock/skills:grill-me" bash <(curl ...)`.

Projektschritte, die mit dem Code wandern sollen, als `<repo>/.claude/cloud-setup.sh` ins Projekt-Repo legen
(Vorlage: `examples/repo-cloud-setup.sh`). Das Skript führt sie automatisch aus.

**Aktualisierung:** Umgebungen bauen ihren Cache nur neu, wenn sich der Text im Setup-Feld ändert oder nach ~7 Tagen.
Für eine feste Version statt `main` einen Tag auf GitHub anlegen und dessen Namen in die URL setzen.
Setup-Log jeder Session: `/var/log/cloud-setup.log`.
