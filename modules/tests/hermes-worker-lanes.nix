{ inputs, self, ... }:
{
  # Worker lane option/catalogue evaluation and Home Manager wiring tests.
  # Ported consumer-neutrally from the original den checks: fixture profiles
  # replace the den runners, and only the portable assertions remain.
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (builtins.hasAttr system inputs.hermes-agent.packages) (
      let
        hermesWithTestDependencies = (inputs.hermes-agent.packages.${system}.default).override {
          extraDependencyGroups = [
            "messaging"
            "dev"
          ];
        };
        patchedHermes = pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/package.nix") {
          hermesAgent = hermesWithTestDependencies;
          src = inputs.hermes-agent;
        };
        codexWorkerLane = pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix") { };
        customCodexWorkerLane = pkgs.callPackage (self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix") {
          lanes = [
            {
              name = "architecture-review";
              description = "architecture decisions that require no file changes";
              approvalPolicy = "never";
              approvalsReviewer = "user";
              sandboxMode = "read-only";
              networkAccess = false;
              maxConcurrency = 1;
            }
            {
              name = "code-with-network";
              description = "implementation that needs access to declared network services";
              approvalPolicy = "never";
              approvalsReviewer = "user";
              sandboxMode = "workspace-write";
              networkAccess = true;
              maxConcurrency = 1;
            }
          ];
        };
        settingsOptions = self.lib.settings;
        catalogueLib = self.lib.catalogue;
        evalWorkerLaneSettings =
          value:
          lib.evalModules {
            modules = [
              {
                options.settings = lib.mkOption {
                  type = lib.types.submodule {
                    options = settingsOptions;
                  };
                };
                config.settings = value;
              }
            ];
          };
        validWorkerLane =
          (evalWorkerLaneSettings {
            instance = "test";
            workerLanes.project = {
              description = "project implementation";
              runtime = "hermes";
              profile = "default";
              agent = {
                model = "test-model";
                reasoningEffort = "high";
                tools = [ "terminal" ];
                skills = [ "nix" ];
              };
              workspace = {
                projectMode = "required";
                projectProvider = "broker-project";
                maximumPermission = "workspace-write";
                supportedSourceKinds = [ "git" ];
                inputs = {
                  maxInputs = 4;
                  maxInputBytes = 16777216;
                  maxInputEntries = 5000;
                  maxInputPathBytes = 2048;
                };
              };
              policy = {
                worklane = "project";
                approvalPolicy = "never";
              };
              execution = {
                timeoutSeconds = 1800;
                maxTurns = 20;
                cpus = 2;
                memoryMiB = 4096;
                diskMiB = 16384;
              };
              maxConcurrency = 2;
            };
            boards.main = {
              allowedLanes = [ "project" ];
              allowedProjects = [ "repository" ];
              defaultProject = "repository";
            };
            projects.repository = {
              title = "Repository";
              source = {
                type = "git";
                repositoryId = "repository";
              };
              laneAccess.project = "workspace-write";
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
          }).config.settings;
        validCatalogue = catalogueLib.resolve validWorkerLane;
        invalidBoardReference = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            validWorkerLane
            // {
              boards.invalid = {
                allowedLanes = [ "missing" ];
                allowedProjects = [ ];
              };
            }
          )) true
        );
        invalidPermissionEscalation = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              workerLanes.project.workspace.maximumPermission = "read-only";
            }
          )) true
        );
        invalidSourceUpstream = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              projectSources.repository.upstream = "https://token@github.com/example/repository.git";
            }
          )) true
        );
        invalidStoreUpstream = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              projectSources.repository.upstream = "/nix/store/abcd-source";
            }
          )) true
        );
        invalidUnknownRepository = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              projects.repository.source.repositoryId = "missing";
            }
          )) true
        );
        invalidCredentialRef = builtins.tryEval (
          builtins.deepSeq ((evalWorkerLaneSettings (
            lib.recursiveUpdate validWorkerLane {
              projectSources.repository.credential.secretRef = "/run/secrets/token";
            }
          )).config.settings) true
        );
        invalidMemoryMode = builtins.tryEval (
          builtins.deepSeq ((evalWorkerLaneSettings {
            workerLanes.invalid = {
              description = "invalid memory mode";
              runtime = "hermes";
              memory = "profile";
            };
          }).config.settings.workerLanes.invalid
          ) true
        );
        invalidUnknownSetting = builtins.tryEval (
          builtins.deepSeq ((evalWorkerLaneSettings {
            instance = "test";
            unknownInfrastructureField = true;
          }).config.settings
          ) true
        );
        invalidInputCeilings = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              workerLanes.project.workspace.inputs.maxInputs = 0;
            }
          )) true
        );
        invalidDetachedApproval = builtins.tryEval (
          builtins.deepSeq (catalogueLib.resolve (
            lib.recursiveUpdate validWorkerLane {
              workerLanes.project.policy.approvalPolicy = "on-request";
            }
          )) true
        );

        # Evaluate the portable Home Manager module with fixture instances,
        # stubbing only the option trees Home Manager itself would provide.
        fixtureLaneSettings = {
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
        fixtureHome =
          (lib.evalModules {
            specialArgs = {
              inherit pkgs;
              # quadlet-nix's Home Manager module consumes lib.hm and a few
              # Home Manager-owned options; stub both for this wiring eval.
              lib = lib.extend (
                final: prev: {
                  hm.dag.entryBefore = after: text: text;
                }
              );
            };
            modules = [
              self.homeManagerModules.hermes
              {
                options.home.stateVersion = lib.mkOption {
                  type = lib.types.str;
                  default = "26.05";
                };
                options.home.activation = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.xdg.configHome = lib.mkOption {
                  type = lib.types.str;
                  default = "/home/fixture/.config";
                };
                options.xdg.configFile = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.systemd = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                options.assertions = lib.mkOption {
                  type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                  default = [ ];
                };
                options.warnings = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
              }
              {
                programs.hermes.instances.fixture = {
                  enable = true;
                  instance = "fixture";
                  userName = "fixture-runner";
                  secureTerminal = {
                    enable = true;
                    backend = "gondolin";
                    workspaceHandoff.enable = true;
                  };
                  settings = fixtureLaneSettings // {
                    instance = "fixture";
                  };
                };
                # A gondolin instance without Codex lanes gets no broker
                # data access at all.
                programs.hermes.instances.plain = {
                  enable = true;
                  instance = "plain";
                  userName = "plain-runner";
                  secureTerminal = {
                    enable = true;
                    backend = "gondolin";
                  };
                  settings.instance = "plain";
                };
              }
            ];
          }).config;
        fixtureContainer =
          fixtureHome.virtualisation.quadlet.containers.hermes-fixture.containerConfig;
        plainContainer =
          fixtureHome.virtualisation.quadlet.containers.hermes-plain.containerConfig;
        fixtureCodexLanes = builtins.fromJSON fixtureContainer.environments.CODEX_WORKER_LANES;
        fixtureVolumes = fixtureContainer.volumes;
        plainVolumes = plainContainer.volumes;
        brokerWorkspaceMount = "/var/lib/hermes-fixture-sandbox/workspaces/data:/home/hermes/broker-workspaces";
      in
      lib.recursiveUpdate
        (lib.recursiveUpdate
          {
          # Exercise non-default lane names and descriptions independently from
          # the generic patched-Hermes/worker runtime test below.
          checks.hermes-codex-worker-lane-custom-skill = customCodexWorkerLane;
          checks.hermes-worker-lane-options =
            assert validWorkerLane.instance == "test";
            assert validWorkerLane.workerLanes.project.memory == "disabled";
            assert validWorkerLane.workerLanes.project.maxConcurrency == 2;
            assert !invalidMemoryMode.success;
            assert !invalidUnknownSetting.success;
            assert builtins.stringLength validCatalogue.revision == 64;
            assert validCatalogue.revision == (catalogueLib.resolve validWorkerLane).revision;
            assert builtins.stringLength validCatalogue.sourceRevisions.repository == 64;
            assert builtins.stringLength validCatalogue.providerRevisions.broker-project == 64;
            assert !invalidBoardReference.success;
            assert !invalidPermissionEscalation.success;
            assert !invalidSourceUpstream.success;
            assert !invalidStoreUpstream.success;
            assert !invalidUnknownRepository.success;
            assert !invalidCredentialRef.success;
            assert !invalidInputCeilings.success;
            assert !invalidDetachedApproval.success;
            assert validCatalogue.workerLanes.project.workspace.inputs.maxInputs == 4;
            assert validCatalogue.workerLanes.project.workspace.inputs.maxInputBytes == 16777216;
            pkgs.runCommand "hermes-worker-lane-options" { } "touch $out";
          checks.hermes-worker-lane =
            pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/check.nix")
              {
                inherit codexWorkerLane patchedHermes;
                sandboxAccess = pkgs.callPackage (self + "/pkgs/by-name/hermes-sandbox-access/package.nix") { };
              };
        }
        (lib.optionalAttrs (lib.hasSuffix "-linux" system) {
          # The quadlet wiring eval instantiates the linux-only Codex package.
          checks.hermes-worker-lane-hm-wiring =
            assert lib.all (lane: lane.networkAccess) fixtureCodexLanes;
            assert lib.all (lane: lane.approvalPolicy == "never") fixtureCodexLanes;
            # Trusted external Codex workers consume broker workspaces through
            # a group-shared host bind mount, never through the guest VFS.
            assert fixtureContainer.unmask == "ALL";
            assert !(fixtureContainer.privileged or false);
            assert !(builtins.elem "CAP_SYS_ADMIN" (fixtureContainer.addCapabilities or [ ]));
            assert lib.elem "keep-groups" fixtureContainer.addGroups;
            assert lib.elem brokerWorkspaceMount fixtureVolumes;
            assert fixtureContainer.environments.HERMES_BROKER_WORKSPACE_DATA == "/home/hermes/broker-workspaces";
            assert lib.hasPrefix "/nix/store/" fixtureContainer.environments.BWRAP_EXECUTABLE;
            assert lib.hasPrefix "/nix/store/" fixtureContainer.environments.BASH_EXECUTABLE;
            assert lib.hasPrefix "/nix/store/" fixtureContainer.environments.ENV_EXECUTABLE;
            assert lib.hasInfix "/nix/store/" fixtureContainer.environments.CODEX_RUNTIME_PATH;
            assert !(plainContainer.environments ? HERMES_BROKER_WORKSPACE_DATA);
            assert !(plainContainer.environments ? BWRAP_EXECUTABLE);
            assert plainContainer.unmask == null;
            assert !(lib.any (lib.hasPrefix "/var/lib/hermes-plain-sandbox/workspaces/") plainVolumes);
            pkgs.runCommand "hermes-worker-lane-hm-wiring" { } "touch $out";
        }))
        (lib.optionalAttrs (system == "x86_64-linux") {
          checks.hermes-codex-minimal-sandbox = pkgs.callPackage (
            self + "/pkgs/by-name/hermes-codex-worker-lane/minimal-sandbox-check.nix"
          ) {
            python = patchedHermes.hermesVenv;
            pythonPath = patchedHermes.patchedSource;
            workerSource = codexWorkerLane.testSource;
          };
        })
    );
}
