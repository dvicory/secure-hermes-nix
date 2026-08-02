{ inputs, self }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  profileType = types.submodule { options = self.lib.options.profileOptions; };
  profiles = config.programs.hermes.instances;

  mkProfile = profileName: profile:
    let
      settings = profile.settings // { instance = profile.instance; };
      catalogue = self.lib.catalogue.resolve settings;
      secure = profile.secureTerminal;
      codex = settings.codex or { };
      codexEnabled = codex.enable or false;
      serviceName = "hermes-${profile.instance}";
      containerHome = "/home/hermes";
      workspaceRoot = "${containerHome}/workspace";
      project = profile.project;
      projectDirectory = project.directory;
      tailscaleName = "${serviceName}-tailscale";
      fortressName = "${serviceName}-fortress";
      sandboxEngine = "${serviceName}-sandbox-engine";
      brokerName = "${serviceName}-broker";
      sandboxSocketHost = "/run/${sandboxEngine}/podman.sock";
      sandboxSocketContainer = "/run/hermes-sandbox/podman.sock";
      brokerSocketContainerDirectory = "/run/hermes-sandbox";
      codexSkillRoot = "/run/hermes-managed-skills";
      hasTailscale = profile.secrets.tailscale != null;
      hasEnvSecret = profile.secrets.env != null;
      hasGithubPat = profile.secrets.githubPat != null;
      codexLanes = lib.mapAttrsToList
        (name: lane: {
          inherit name;
          inherit (lane) description maxConcurrency;
          approvalPolicy = lane.policy.approvalPolicy;
          approvalsReviewer = lane.policy.approvalReviewer;
          sandboxMode = lane.workspace.maximumPermission;
          workspaceKinds =
            if (lane.workspace.projectProvider or null) == "broker-project" then
              [ "broker" ]
            else if (lane.workspace.projectProvider or null) == "host-worktree" then
              [ "worktree" ]
            else
              [ "scratch" ];
          networkAccess = lane.policy.networkAccess;
        })
        (lib.filterAttrs (_: lane: lane.runtime == "external" && lane.plugin == "codex-cli") catalogue.workerLanes);
      codexWorkerLane = pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix") {
        lanes = codexLanes;
      };
      codexPackage =
        if codexEnabled then
          inputs.llm-agents.packages.${pkgs.system}.codex
        else
          null;
      image = profile.settings.image or "localhost/hermes-agent:${pkgs.system}-dirty";
      configFile = (pkgs.formats.yaml { }).generate "${serviceName}-config.yaml" (
        {
          _config_version = 33;
          terminal =
            if secure.enable && secure.backend == "gondolin" then
              {
                backend = "gondolin";
                cwd = "/workspace";
                timeout = 180;
                lifetime_seconds = secure.lifetimeSeconds;
              }
            else if secure.enable then
              {
                backend = "docker";
                cwd = "/workspace";
                timeout = 180;
                lifetime_seconds = secure.lifetimeSeconds;
                docker_image = secure.image;
                container_cpu = secure.cpus;
                container_memory = secure.memoryMiB;
                container_disk = secure.diskMiB;
                container_persistent = true;
                docker_network = secure.network;
                docker_mount_cwd_to_workspace = false;
                docker_forward_env = [ ];
                docker_volumes = [ ];
                docker_env = { };
                docker_extra_args = [ ];
                docker_persist_across_processes = false;
                docker_orphan_reaper = true;
              }
            else
              {
                backend = "local";
                cwd = workspaceRoot;
                timeout = 180;
              };
          approvals = {
            mode = "manual";
            cron_mode = "deny";
          };
          plugins.enabled = lib.optional codexEnabled "codex-worker-lane"
            ++ lib.optional (secure.enable && secure.backend == "gondolin") "sandbox-access";
          platform_toolsets = {
            cli = [ "hermes-cli" ]
              ++ lib.optional codexEnabled "kanban"
              ++ lib.optional (secure.enable && secure.backend == "gondolin") "sandbox_access";
            telegram = [ "hermes-telegram" ]
              ++ lib.optional codexEnabled "kanban"
              ++ lib.optional (secure.enable && secure.backend == "gondolin") "sandbox_access";
          };
          tool_loop_guardrails = {
            hard_stop_enabled = true;
            hard_stop_after = {
              exact_failure = 5;
              same_tool_failure = 8;
              idempotent_no_progress = 5;
            };
          };
          kanban = {
            dispatch_in_gateway = codexEnabled;
            dispatch_interval_seconds = 60;
            failure_limit = 2;
            max_in_progress_per_profile = 1;
            worker_catalogue = {
              version = 1;
              inherit (catalogue)
                boards
                instance
                laneRevisions
                projectRevisions
                projects
                providerRevisions
                revision
                sourceRevisions
                ;
              lanes = catalogue.workerLanes;
            };
          };
        }
        // (profile.settings.config or { })
        // lib.optionalAttrs codexEnabled {
          skills.external_dirs = [ codexSkillRoot ];
        }
      );
      soulFile = pkgs.writeText "${serviceName}-SOUL.md" (
        profile.settings.soul or ''
          # Hermes

          You are a configured Secure Hermes assistant. Follow the operator's
          declared worker, project, approval, and sandbox policy. Ask before
          taking external actions and never bypass the configured review path.
        ''
      );
      commonVolumes = [
        "${serviceName}-state:${containerHome}/.hermes"
        "${serviceName}-workspace:${containerHome}/workspace"
        "${configFile}:${containerHome}/.hermes/config.yaml:ro"
        "${soulFile}:${containerHome}/.hermes/SOUL.md:ro"
      ]
      ++ lib.optional hasEnvSecret "${profile.secrets.env}:/run/secrets/hermes-env:ro"
      ++ lib.optional hasGithubPat "${profile.secrets.githubPat}:/run/secrets/hermes-github-pat:ro"
      ++ lib.optional (secure.enable && secure.backend == "podman") "${sandboxSocketHost}:${sandboxSocketContainer}"
      ++ lib.optional (secure.enable && secure.backend == "gondolin")
        "/run/${brokerName}:${brokerSocketContainerDirectory}:ro"
      ++ lib.optional codexEnabled "${serviceName}-codex:${containerHome}/.codex"
      ++ lib.optional codexEnabled "${codexWorkerLane}/share/hermes-agent/external-skills:${codexSkillRoot}:ro";
      containerEnvironment = {
        HOME = containerHome;
        HERMES_HOME = "${containerHome}/.hermes";
        CODEX_HOME = "${containerHome}/.codex";
        WORKSPACE_ROOT = workspaceRoot;
        HERMES_PROJECT_NAME = project.name;
        HERMES_PROJECT_TITLE = project.title;
        HERMES_PROJECT_BOARD = project.board;
        HERMES_PROJECT_DIR = projectDirectory;
        HERMES_LEGACY_PROJECT_DIR = project.legacyDirectory;
        HERMES_PROJECT_REPOSITORY = project.repository or "";
        HERMES_PROJECT_DEFAULT_REF = project.defaultRef;
        SECRETS_DIR = "/run/secrets";
      }
      // lib.optionalAttrs (secure.enable && secure.backend == "podman") {
        DOCKER_HOST = "unix://${sandboxSocketContainer}";
        HERMES_DOCKER_BINARY = "${pkgs.docker-client}/bin/docker";
        TERMINAL_ISOLATION_SCOPE = "conversation";
        TERMINAL_DOCKER_STORAGE = "named-volume";
        TERMINAL_DOCKER_MOUNT_SUPPORT_FILES = "false";
      }
      // lib.optionalAttrs (secure.enable && secure.backend == "gondolin") {
        HERMES_GONDOLIN_SOCKET = "${brokerSocketContainerDirectory}/broker.sock";
        GONDOLIN_EFFECT_CONTROL_SOCKET = "${brokerSocketContainerDirectory}/control.sock";
        HERMES_SANDBOX_AUTHORITY_BINDING = "${serviceName}:hermes-gateway:default:v1";
        TERMINAL_ISOLATION_SCOPE = "conversation";
        HERMES_WORKSPACE_HANDOFF = if secure.workspaceHandoff.enable then "1" else "0";
      }
      // lib.optionalAttrs codexEnabled {
        CODEX_EXECUTABLE = "${codexPackage}/bin/codex";
        CODEX_WORKER_LANES = builtins.toJSON codexLanes;
      };
    in
    lib.optionalAttrs profile.enable {
      home.stateVersion = lib.mkDefault "26.05";
      assertions = lib.optionals codexEnabled [
        {
          assertion = builtins.hasAttr pkgs.system inputs.llm-agents.packages;
          message = "${serviceName}: Codex is enabled but llm-agents has no ${pkgs.system} package";
        }
        {
          assertion = lib.all (lane: lane.approvalPolicy == "never") codexLanes;
          message = "${serviceName}: detached Codex lanes must disable approvals";
        }
      ];
      virtualisation.quadlet.containers = {
        ${serviceName} = {
          autoStart = true;
          containerConfig = {
            inherit image;
            environments = containerEnvironment;
            volumes = commonVolumes;
            networks = lib.optional hasTailscale "container:${tailscaleName}";
            addGroups = lib.optional (secure.enable && secure.backend == "gondolin" && codexEnabled) "keep-groups";
          };
        };
      }
      // lib.optionalAttrs hasTailscale {
        ${tailscaleName} = {
          autoStart = true;
          containerConfig = {
            image = "docker.io/tailscale/tailscale:latest";
            addCapabilities = [ "NET_ADMIN" ];
            devices = [ "/dev/net/tun" ];
            environments = {
              TS_STATE_DIR = "/var/lib/tailscale";
              TS_AUTHKEY = "file:/run/secrets/tailscale-auth-key";
              TS_HOSTNAME = "${serviceName}";
            };
            volumes = [
              "${tailscaleName}:/var/lib/tailscale"
              "${profile.secrets.tailscale}:/run/secrets/tailscale-auth-key:ro"
            ];
          };
        };
      };
    };
  generated = lib.mapAttrsToList mkProfile profiles;
  mergeAttr =
    path:
    lib.foldl' (
      acc: item:
      lib.recursiveUpdate acc (lib.attrByPath path { } item)
    ) { } generated;
  appendAttr = path: lib.concatLists (map (lib.attrByPath path [ ]) generated);
  profilesEnabled = lib.any (profile: profile.enable) (lib.attrValues profiles);
in
{
  imports = [ inputs.quadlet-nix.homeManagerModules.quadlet ];

  options.programs.hermes.instances = mkOption {
    type = types.attrsOf profileType;
    default = { };
    description = "Option-driven Secure Hermes Home Manager profiles.";
  };

  config.home.stateVersion = lib.mkIf profilesEnabled (lib.mkDefault "26.05");
  config.assertions = appendAttr [ "assertions" ];
  config.virtualisation.quadlet.containers =
    mergeAttr [ "virtualisation" "quadlet" "containers" ];
}
