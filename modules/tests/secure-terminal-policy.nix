{ self, ... }:
{
  # Policy rendering and module wiring tests for the Effect broker. Nix
  # renders a fixture profile policy and evaluates the portable NixOS module
  # against a fixture instance; assertions pin the rendered contract and the
  # systemd wiring. Ported consumer-neutrally from the original den checks.
  perSystem =
    { pkgs, ... }:
    let
      lib = pkgs.lib;
      policyLib = self.lib.policy;
      catalogueLib = self.lib.catalogue;

      # Fixture selections standing in for consumer choices. No credential
      # capabilities: portable defaults ship none, and consumers inject
      # reviewed ones.
      fixtureSelections = {
        profile = "hermes-fixture";
        defaultTemplate = "project";
        allowedPairs = [
          {
            asset = "general";
            template = "project";
          }
          {
            asset = "general";
            template = "research";
          }
          {
            asset = "general";
            template = "offline";
          }
          {
            asset = "minimal";
            template = "offline";
          }
        ];
        maximum = {
          networkBundles = [
            "git-public"
            "npm-public"
            "pypi-public"
            "nix-cache-public"
          ];
          credentialCapabilities = [ ];
          resources = {
            cpus = 4;
            memoryMiB = 8192;
            diskMiB = 32768;
          };
          grantScopes = [
            "once"
            "task"
          ];
        };
        worklanes.codex = {
          allowedPairs = [
            {
              asset = "general";
              template = "project";
            }
            {
              asset = "minimal";
              template = "offline";
            }
          ];
          maximum.networkBundles = [
            "git-public"
            "npm-public"
            "pypi-public"
          ];
        };
        laneAuthorities = {
          research = {
            authorityClass = "default";
            workspaceProvider = "broker-scratch";
            maximumPermission = "workspace-write";
          };
          codex-plan = {
            authorityClass = "codex";
            workspaceProvider = "broker-project";
            maximumPermission = "read-only";
          };
          codex = {
            authorityClass = "codex";
            workspaceProvider = "broker-project";
            maximumPermission = "workspace-write";
          };
        };
        projectSources = {
          repository = {
            type = "git";
            upstream = "https://github.com/example/repository.git";
            defaultRef = "main";
            credential = {
              adapter = "github-token";
              secretRef = "fixture-github";
            };
          };
        };
        workspaceHandoffEnabled = true;
        workspaceHandoffLimits = {
          maxLogicalBytes = 67108864;
          maxEntries = 8192;
          maxFileBytes = 16777216;
          maxPathBytes = 1024;
        };
      };

      assetManifest =
        name: buildId:
        pkgs.runCommand "asset-${name}-manifest" { } ''
          mkdir -p $out
          echo '{"version":1,"buildId":"${buildId}"}' > $out/manifest.json
        '';
      assets = {
        general = assetManifest "general" "fixture-build-general";
        minimal = assetManifest "minimal" "fixture-build-minimal";
      };

      effectBroker = pkgs.callPackage (self + "/pkgs/by-name/gondolin-broker-effect/package.nix") { };

      effectPolicy = policyLib.mkEffectPolicy {
        inherit pkgs;
        assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) assets;
        bundles = self.lib.networkBundles;
        profile = fixtureSelections.profile;
        defaultTemplate = fixtureSelections.defaultTemplate;
        allowedPairs = fixtureSelections.allowedPairs;
        maximum = fixtureSelections.maximum;
        inherit (fixtureSelections) worklanes laneAuthorities projectSources;
        sourceRevisions = catalogueLib.sourceRevisionsFor fixtureSelections.projectSources;
        providerRevisions = catalogueLib.providerRevisionsFor catalogueLib.providerContracts;
        workspaceHandoffEnabled = fixtureSelections.workspaceHandoffEnabled;
        workspaceHandoffLimits = fixtureSelections.workspaceHandoffLimits;
      };

      # Evaluate the portable NixOS module with a fixture instance, stubbing
      # only the option trees the module writes into.
      fixtureHost =
        (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            self.nixosModules.hermes
            {
              options.assertions = lib.mkOption {
                type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                default = [ ];
              };
              options.users.groups = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
                default = { };
              };
              options.users.users = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
                default = { };
              };
              options.systemd.tmpfiles.rules = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              options.systemd.sockets = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
                default = { };
              };
              options.systemd.services = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
                default = { };
              };
            }
            {
              services.hermes.instances.fixture = {
                enable = true;
                instance = "fixture";
                userName = "fixture-runner";
                secrets.githubPat = "/run/secrets/fixture-github-pat";
                secureTerminal = {
                  enable = true;
                  backend = "gondolin";
                  maximum.networkBundles = [
                    "git-public"
                    "npm-public"
                    "pypi-public"
                    "nix-cache-public"
                  ];
                  workspaceHandoff.enable = true;
                };
                settings = {
                  instance = "fixture";
                  codex.enable = true;
                  workerLanes.codex = {
                    description = "fixture external Codex lane";
                    runtime = "external";
                    plugin = "codex-cli";
                    workspace = {
                      projectMode = "required";
                      projectProvider = "broker-project";
                      maximumPermission = "workspace-write";
                      supportedSourceKinds = [ "git" ];
                      inputs = { };
                    };
                    policy = {
                      worklane = "codex";
                      approvalPolicy = "never";
                      approvalReviewer = "user";
                      networkAccess = true;
                    };
                  };
                  boards.main = {
                    allowedLanes = [ "codex" ];
                    allowedProjects = [ "repository" ];
                    defaultProject = "repository";
                  };
                  projects.repository = {
                    title = "Repository";
                    source = {
                      type = "git";
                      repositoryId = "repository";
                    };
                    laneAccess.codex = "workspace-write";
                  };
                  projectSources.repository = {
                    type = "git";
                    upstream = "https://github.com/example/repository.git";
                    defaultRef = "main";
                    credential = {
                      adapter = "github-token";
                      secretRef = "fixture-github";
                    };
                  };
                };
              };
            }
          ];
        }).config;
      fixtureExecutionSocket = fixtureHost.systemd.sockets.hermes-fixture-broker-execution.socketConfig;
      fixtureControlSocket = fixtureHost.systemd.sockets.hermes-fixture-broker-control.socketConfig;
      fixtureBrokerEnvironment = fixtureHost.systemd.services.hermes-fixture-broker.environment;
      fixtureBrokerHardening = fixtureHost.systemd.services.hermes-fixture-broker.serviceConfig;
    in
    {
      checks.secure-terminal-policy =
        assert lib.elem "d /run/hermes-fixture-broker 0711 root root -" fixtureHost.systemd.tmpfiles.rules;
        assert fixtureExecutionSocket.DirectoryMode == "0711";
        assert fixtureExecutionSocket.ListenStream == "/run/hermes-fixture-broker/broker.sock";
        assert fixtureExecutionSocket.SocketMode == "0600";
        assert fixtureExecutionSocket.SocketUser == "fixture-runner";
        assert fixtureControlSocket.DirectoryMode == "0711";
        assert fixtureControlSocket.ListenStream == "/run/hermes-fixture-broker/control.sock";
        assert fixtureControlSocket.SocketMode == "0600";
        assert fixtureControlSocket.SocketUser == "fixture-runner";
        assert fixtureBrokerEnvironment.GONDOLIN_EFFECT_STATE_DIR == "/var/lib/hermes-fixture-sandbox";
        assert fixtureBrokerEnvironment.GONDOLIN_EFFECT_WORKSPACE_HANDOFF == "true";
        assert fixtureBrokerEnvironment.GONDOLIN_EFFECT_SOCKET == "/run/hermes-fixture-broker/broker.sock";
        assert fixtureBrokerEnvironment.GONDOLIN_EFFECT_CONTROL_SOCKET == "/run/hermes-fixture-broker/control.sock";
        assert fixtureBrokerHardening.ProtectControlGroups;
        assert fixtureBrokerHardening.DevicePolicy == "closed";
        assert lib.elem "/dev/kvm rw" fixtureBrokerHardening.DeviceAllow;
        assert fixtureBrokerHardening.CapabilityBoundingSet == "";
        # Workspaces are shared with the runner through their setgid sandbox
        # group; the broker must be allowed to chmod them.
        assert !fixtureBrokerHardening.RestrictSUIDSGID;
        # Input materialization preserves ownership via fchown(2).
        assert lib.elem "fchown" fixtureBrokerHardening.SystemCallFilter;
        assert lib.elem "fixture-runner" fixtureHost.users.groups.hermes-fixture-sandbox.members;
        assert fixtureBrokerHardening.StateDirectoryMode == "0750";
        assert lib.any (
          lib.hasPrefix "source-hermes-terminal-github:/run/secrets/fixture-github-pat"
        ) fixtureBrokerHardening.LoadCredential;
        assert effectPolicy.policyMaterial.processRegistry == {
          maxConcurrent = 8;
          retainedOutputBytes = 262144;
          maxPollBytes = 1048576;
          terminalTtlMs = 1800000;
        };
        pkgs.runCommand "secure-terminal-policy" { } ''
          touch $out
        '';
      checks.secure-terminal-effect-policy-http =
        pkgs.runCommand "secure-terminal-effect-policy-http"
          {
            nativeBuildInputs = [ pkgs.nodejs_24 ];
            policyJson = "${effectPolicy.json}";
          }
          ''
            export GONDOLIN_EFFECT_POLICY="$policyJson"
            export GONDOLIN_EFFECT_PROFILE=hermes-fixture
            export GONDOLIN_EFFECT_STATE_DIR="$TMPDIR/state"
            export GONDOLIN_EFFECT_SOCKET="$TMPDIR/broker.sock"
            export GONDOLIN_EFFECT_CONTROL_SOCKET="$TMPDIR/control.sock"
            export GONDOLIN_EFFECT_WORKSPACE_HANDOFF=true
            node ${effectBroker}/lib/node_modules/gondolin-broker-effect/dist/test-main.js >"$TMPDIR/broker.log" 2>&1 &
            broker_pid=$!
            trap 'kill "$broker_pid" 2>/dev/null || true' EXIT
            for _ in $(seq 1 100); do
              [ -S "$GONDOLIN_EFFECT_SOCKET" ] && [ -S "$GONDOLIN_EFFECT_CONTROL_SOCKET" ] && break
              if ! kill -0 "$broker_pid"; then
                cat "$TMPDIR/broker.log"
                exit 1
              fi
              sleep 0.05
            done
            [ -S "$GONDOLIN_EFFECT_SOCKET" ]
            [ -S "$GONDOLIN_EFFECT_CONTROL_SOCKET" ]
            if ! node ${self + "/modules/tests/secure-terminal-effect-policy-http.mjs"}; then
              cat "$TMPDIR/broker.log"
              exit 1
            fi
            kill "$broker_pid"
            wait "$broker_pid" || true
            trap - EXIT
            touch $out
          '';
    };
}
