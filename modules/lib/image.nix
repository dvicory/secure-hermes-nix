{ inputs, self }:
{
  pkgs,
  system,
  hermesAgent,
  imageName ? "hermes-agent",
  imageTag ? "${system}-dirty",
  project ? { },
  includeCodex ? true,
  workerLanes ? null,
}:
let
  lib = pkgs.lib;
  hermesPackage = pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/package.nix") {
    inherit hermesAgent;
    src = inputs.hermes-agent;
  };
  codexPackage =
    if includeCodex && lib.hasAttrByPath [ system "codex" ] inputs.llm-agents.packages then
      inputs.llm-agents.packages.${system}.codex
    else
      null;
  codexWorkerLane = pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix") (
    lib.optionalAttrs (workerLanes != null) { lanes = workerLanes; }
  );
  sandboxAccess = pkgs.callPackage (self + "/pkgs/by-name/hermes-sandbox-access/package.nix") { };
  projectName = project.name or "project";
  projectTitle = project.title or projectName;
  projectBoard = project.board or projectName;
  projectRepository = project.repository or "";
  projectDirectory = project.directory or "/home/hermes/workspace/projects/${projectName}";
  legacyProjectDirectory = project.legacyDirectory or "/home/hermes/workspace/${projectName}";
  terminalBaseline = with pkgs; [
    bash
    coreutils
    curl
    file
    findutils
    gawk
    gnugrep
    gnused
    gnutar
    gzip
    python3
    ripgrep
  ];
  entrypoint = pkgs.runCommand "${imageName}-entrypoint" { } ''
    install -Dm555 ${pkgs.writeShellScript "${imageName}-entrypoint.sh" ''
      set -euo pipefail

      export HERMES_MANAGED=true
      mkdir -p "$HERMES_HOME"
      touch "$HERMES_HOME/.managed"
      mkdir -p "$HERMES_HOME"/{cron,sessions,logs,memories,plugins}

      if [ -f "$SECRETS_DIR/hermes-env" ]; then
        install -m 0600 "$SECRETS_DIR/hermes-env" "$HERMES_HOME/.env"
      fi

      if [ -f "$SECRETS_DIR/hermes-github-pat" ]; then
        PAT=$(cat "$SECRETS_DIR/hermes-github-pat")
        echo "$PAT" | gh auth login --with-token
        gh auth setup-git
        git config --global user.name "Hermes Agent"
        git config --global user.email "hermes-agent@users.noreply.github.com"
        unset PAT
      fi

      log() {
        echo "[hermes-entrypoint] $*" >&2
      }

      if [ -n "''${HERMES_PROJECT_REPOSITORY:-}" ] && [ ! -d "$HERMES_PROJECT_DIR/.git" ]; then
        if [ -e "$HERMES_PROJECT_DIR" ] && [ -n "$(find "$HERMES_PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
          log "refusing to clone into non-empty, non-Git project directory: $HERMES_PROJECT_DIR"
          exit 1
        fi
        log "cloning declared project '$HERMES_PROJECT_NAME' into $HERMES_PROJECT_DIR"
        mkdir -p "$(dirname "$HERMES_PROJECT_DIR")"
        git clone "$HERMES_PROJECT_REPOSITORY" "$HERMES_PROJECT_DIR"
      fi

      if [ -e "$HERMES_LEGACY_PROJECT_DIR" ] && [ "$HERMES_LEGACY_PROJECT_DIR" != "$HERMES_PROJECT_DIR" ]; then
        log "removing obsolete project checkout: $HERMES_LEGACY_PROJECT_DIR"
        rm -rf "$HERMES_LEGACY_PROJECT_DIR"
      fi

      if [ -n "''${HERMES_PROJECT_REPOSITORY:-}" ] && [ -d "$HERMES_PROJECT_DIR/.git" ]; then
        if ! git -C "$HERMES_PROJECT_DIR" remote get-url origin >/dev/null; then
          log "project checkout has no origin remote: $HERMES_PROJECT_DIR"
          exit 1
        fi
        if ! git -C "$HERMES_PROJECT_DIR" fetch origin "''${HERMES_PROJECT_DEFAULT_REF:-main}"; then
          log "warning: could not fetch origin/''${HERMES_PROJECT_DEFAULT_REF:-main}; using existing checkout"
        fi
        if [ -n "$(git -C "$HERMES_PROJECT_DIR" status --porcelain)" ]; then
          log "warning: declared project checkout is dirty; preserving it without reset"
        fi

        project_catalogue_marker="$HERMES_HOME/.managed-project-catalogue-v1"
        if [ ! -e "$project_catalogue_marker" ]; then
          project_exists() {
            hermes project list --all | ${pkgs.gawk}/bin/awk \
              -v slug="$HERMES_PROJECT_NAME" \
              '$1 == slug || ($1 == "*" && $2 == slug) { found = 1 } END { exit !found }' \
              || return 1
          }

          log "initializing managed project catalogue"
          hermes kanban boards create "$HERMES_PROJECT_BOARD" \
            --name "$HERMES_PROJECT_TITLE" \
            --default-workdir "$HERMES_PROJECT_DIR" || exit 1
          if ! project_exists; then
            hermes project create "$HERMES_PROJECT_TITLE" "$HERMES_PROJECT_DIR" \
              --slug "$HERMES_PROJECT_NAME" \
              --primary "$HERMES_PROJECT_DIR" \
              --board "$HERMES_PROJECT_BOARD" \
              --use || exit 1
          fi
          project_exists || exit 1
          hermes project bind-board "$HERMES_PROJECT_NAME" "$HERMES_PROJECT_BOARD" || exit 1
          hermes kanban boards switch "$HERMES_PROJECT_BOARD" || exit 1
          touch "$project_catalogue_marker"
        fi
      fi

      rm -rf ${hermesPackage}/share/hermes-agent/plugins/cron 2>/dev/null || true

      rm -rf "$HERMES_HOME/plugins/codex-worker-lane"
      cp -R ${codexWorkerLane}/share/hermes-agent/plugins/codex-worker-lane \
        "$HERMES_HOME/plugins/codex-worker-lane"
      chmod -R u=rwX,go=rX "$HERMES_HOME/plugins/codex-worker-lane"

      rm -rf "$HERMES_HOME/plugins/sandbox-access"
      cp -R ${sandboxAccess}/share/hermes-agent/plugins/sandbox-access \
        "$HERMES_HOME/plugins/sandbox-access"
      chmod -R u=rwX,go=rX "$HERMES_HOME/plugins/sandbox-access"

      exec ${hermesPackage}/bin/hermes gateway "$@"
    ''} $out/entrypoint
  '';
  contents = [
    hermesPackage
    pkgs.agent-browser
    pkgs.git
    pkgs.gh
    pkgs.jq
    pkgs.cacert
    pkgs.docker-client
    # External Codex workers use a per-process mount namespace so broker
    # storage is visible only through the canonical /workspace planes.
    pkgs.bubblewrap
    codexWorkerLane
    entrypoint
  ] ++ lib.optional (codexPackage != null) codexPackage ++ terminalBaseline;
  env = [
    "HERMES_MANAGED=true"
    "HOME=/home/hermes"
    "HERMES_HOME=/home/hermes/.hermes"
    "CODEX_HOME=/home/hermes/.codex"
    "WORKSPACE_ROOT=/home/hermes/workspace"
    "HERMES_PROJECT_NAME=${projectName}"
    "HERMES_PROJECT_TITLE=${projectTitle}"
    "HERMES_PROJECT_BOARD=${projectBoard}"
    "HERMES_PROJECT_DIR=${projectDirectory}"
    "HERMES_LEGACY_PROJECT_DIR=${legacyProjectDirectory}"
    "HERMES_PROJECT_REPOSITORY=${projectRepository}"
    "SECRETS_DIR=/run/secrets"
    "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
  ];
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  inherit contents;
  config = {
    Entrypoint = [ "/entrypoint" ];
    WorkingDir = "/home/hermes";
    inherit env;
  };
  fakeRootCommands = ''
    mkdir -p ./usr/bin ./home/hermes/.hermes ./home/hermes/workspace ./tmp
    chmod 1777 ./tmp
    ln -s /bin/env ./usr/bin/env
  '';
}
