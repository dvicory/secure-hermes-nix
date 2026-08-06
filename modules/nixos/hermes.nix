{ inputs, self }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  profileOptions = self.lib.options.profileOptions;
  profileType = types.submodule { options = profileOptions; };

  mkInstance = instanceName: profile:
    let
      cfg = profile.secureTerminal;
      enabled = profile.enable;
      gondolin = enabled && cfg.enable && cfg.backend == "gondolin";
      podman = enabled && cfg.enable && cfg.backend == "podman";
      serviceName = "hermes-${profile.instance}";
      sandboxUser = "${serviceName}-sandbox";
      sandboxEngine = "${serviceName}-sandbox-engine";
      brokerName = "${serviceName}-broker";
      executionSocketName = "${brokerName}-execution";
      controlSocketName = "${brokerName}-control";
      executionSocketPath = "/run/${brokerName}/broker.sock";
      controlSocketPath = "/run/${brokerName}/control.sock";
      sandboxUid = if profile.uid == null then null else profile.uid + 50;
      sandboxSubIdStart = if sandboxUid == null then null else 100000 + ((sandboxUid - 1000) * 65536);
      projectSources = profile.settings.projectSources or { };
      catalogue = self.lib.catalogue.resolve profile.settings;
      policy =
        if gondolin then
          let
            policyLib = self.lib.policy;
            guestAssets = self.lib.guestAssets.mkGuestAssets pkgs.stdenv.hostPlatform.system;
            laneAuthorities = lib.mapAttrs (
              _: lane:
              let
                workspace = lane.workspace or { };
                projectMode = workspace.projectMode or "none";
              in
              {
                authorityClass = lane.policy.worklane or "default";
                workspaceProvider =
                  if projectMode == "none" then
                    workspace.scratchProvider or "broker-scratch"
                  else
                    workspace.projectProvider or "broker-project";
                maximumPermission =
                  if projectMode == "none" then "workspace-write" else workspace.maximumPermission;
              }
            ) profile.settings.workerLanes;
            maximum = {
              networkBundles = cfg.maximum.networkBundles;
              credentialCapabilities = cfg.maximum.credentialCapabilities;
              resources = cfg.maximum.resources;
              grantScopes = cfg.maximum.grantScopes;
            };
          in
          policyLib.mkEffectPolicy {
            inherit pkgs guestAssets;
            profile = serviceName;
            bundles = self.lib.networkBundles;
            assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) guestAssets;
            defaultTemplate = cfg.defaultTemplate;
            allowedPairs = cfg.allowedPairs;
            worklanes = cfg.worklanes;
            inherit laneAuthorities maximum projectSources;
            workspaceHandoffEnabled = cfg.workspaceHandoff.enable;
            workspaceHandoffLimits = cfg.workspaceHandoff.handoffLimits;
            sourceRevisions = self.lib.catalogue.sourceRevisionsFor projectSources;
            providerRevisions = self.lib.catalogue.providerRevisionsFor self.lib.catalogue.providerContracts;
            projectMaterializationLimits = cfg.projectMaterializationLimits;
          }
        else
          null;
      brokerPackage =
        if gondolin then
          pkgs.callPackage (self + "/pkgs/by-name/gondolin-broker-effect/package.nix") { }
        else
          null;
      brokerCredential = profile.secrets.githubPat;
      commonSecurity = {
        UMask = "0077";
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectControlGroups = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        LockPersonality = true;
        RestrictRealtime = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        PrivateMounts = true;
      };
    in
    lib.mkMerge [
      {
        assertions = lib.optional (gondolin && sandboxUid != null) {
          assertion = sandboxUid >= 1050 && sandboxUid < 10000;
          message = "${serviceName}: sandbox UID must be a stable non-system UID";
        };
        users.groups.${sandboxUser} = { };
        users.users.${sandboxUser} = {
          isNormalUser = true;
          group = sandboxUser;
          home = "/var/lib/${sandboxUser}";
          createHome = true;
          autoSubUidGidRange = false;
        } // lib.optionalAttrs (sandboxUid != null) {
          uid = sandboxUid;
          subUidRanges = [ { startUid = sandboxSubIdStart; count = 65536; } ];
          subGidRanges = [ { startGid = sandboxSubIdStart; count = 65536; } ];
        };
      }
      (lib.mkIf podman {
        systemd.sockets.${sandboxEngine} = {
          description = "${serviceName} isolated terminal Podman API";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "/run/${sandboxEngine}/podman.sock";
            SocketUser = profile.userName;
            SocketGroup = profile.userName;
            SocketMode = "0600";
            DirectoryMode = "0711";
            RemoveOnStop = true;
          };
        };
        systemd.services.${sandboxEngine} = {
          description = "${serviceName} isolated terminal Podman service";
          environment = {
            HOME = "/var/lib/${sandboxUser}";
            XDG_DATA_HOME = "/var/lib/${sandboxUser}/.local/share";
            XDG_RUNTIME_DIR = "/run/${sandboxUser}";
          };
          serviceConfig = commonSecurity // {
            Type = "exec";
            User = sandboxUser;
            Group = sandboxUser;
            ExecStart = "${pkgs.podman}/bin/podman --log-level=info system service --time=0";
            Delegate = true;
            KillMode = "process";
            TimeoutStopSec = 70;
            StateDirectory = sandboxUser;
            StateDirectoryMode = "0700";
            RuntimeDirectory = sandboxUser;
            RuntimeDirectoryMode = "0700";
          };
        };
      })
      (lib.mkIf gondolin {
        systemd.tmpfiles.rules = [ "d /run/${brokerName} 0711 root root -" ];
        systemd.sockets.${executionSocketName} = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = executionSocketPath;
            FileDescriptorName = "execution";
            Service = "${brokerName}.service";
            SocketUser = profile.userName;
            SocketGroup = profile.userName;
            SocketMode = "0600";
            DirectoryMode = "0711";
            RemoveOnStop = true;
          };
        };
        systemd.sockets.${controlSocketName} = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = controlSocketPath;
            FileDescriptorName = "control";
            Service = "${brokerName}.service";
            SocketUser = profile.userName;
            SocketGroup = profile.userName;
            SocketMode = "0600";
            DirectoryMode = "0711";
            RemoveOnStop = true;
          };
        };
        systemd.services.${brokerName} = {
          description = "${serviceName} Gondolin sandbox broker";
          requires = [ "${executionSocketName}.socket" "${controlSocketName}.socket" ];
          after = [ "${executionSocketName}.socket" "${controlSocketName}.socket" ];
          path = [ pkgs.qemu ];
          unitConfig.ConditionPathExists = "/dev/kvm";
          environment = {
            GONDOLIN_EFFECT_POLICY = "${policy.json}";
            GONDOLIN_EFFECT_PROFILE = serviceName;
            GONDOLIN_EFFECT_STATE_DIR = "/var/lib/${sandboxUser}";
            GONDOLIN_EFFECT_SOCKET = executionSocketPath;
            GONDOLIN_EFFECT_CONTROL_SOCKET = controlSocketPath;
            GONDOLIN_EFFECT_WORKSPACE_HANDOFF = if cfg.workspaceHandoff.enable then "true" else "false";
            GONDOLIN_DEBUG = "protocol,net";
          };
          serviceConfig = commonSecurity // {
            Type = "exec";
            User = sandboxUser;
            Group = sandboxUser;
            ExecStart = "${brokerPackage}/bin/gondolin-broker-effect";
            StateDirectory = sandboxUser;
            StateDirectoryMode = "0750";
            CacheDirectory = sandboxUser;
            CacheDirectoryMode = "0700";
            RuntimeDirectory = sandboxUser;
            RuntimeDirectoryMode = "0700";
            ReadWritePaths = [ "/var/lib/${sandboxUser}" "/var/cache/${sandboxUser}" "/run/${sandboxUser}" ];
            # Workspaces are shared with the runner through their setgid
            # sandbox group. RestrictSUIDSGID blocks the required chmod(2)
            # with EPERM even though the broker owns the directory.
            RestrictSUIDSGID = false;
            LoadCredential = lib.optional (brokerCredential != null) "source-hermes-terminal-github:${brokerCredential}";
            DevicePolicy = "closed";
            DeviceAllow = [ "/dev/kvm rw" ];
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
            SystemCallArchitectures = "native";
            SystemCallFilter = [ "@system-service" "~@privileged" ];
            KillMode = "mixed";
            TimeoutStopSec = 70;
          };
        };
      })
    ];
  profiles = config.services.hermes.instances;
  generated = lib.mapAttrsToList mkInstance profiles;
  mergeAttr =
    path:
    lib.foldl' (
      acc: item:
      lib.recursiveUpdate acc (lib.attrByPath path { } item)
    ) { } generated;
  appendAttr = path: lib.concatLists (map (lib.attrByPath path [ ]) generated);
in
{
  options.services.hermes.instances = mkOption {
    type = types.attrsOf profileType;
    default = { };
    description = "Option-driven Secure Hermes host profiles.";
  };

  config.assertions = appendAttr [ "assertions" ];
  config.users.groups = mergeAttr [ "users" "groups" ];
  config.users.users = mergeAttr [ "users" "users" ];
  config.systemd.tmpfiles.rules = appendAttr [ "systemd" "tmpfiles" "rules" ];
  config.systemd.sockets = mergeAttr [ "systemd" "sockets" ];
  config.systemd.services = mergeAttr [ "systemd" "services" ];
}
