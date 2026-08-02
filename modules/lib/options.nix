{ lib }:
let
  inherit (lib) mkEnableOption mkOption types;
  settingsType = types.submodule { options = import ./settings.nix { inherit lib; }; };
  pathType = types.nullOr (types.either types.path types.str);
  resourceType = types.submodule {
    options = {
      cpus = mkOption { type = types.ints.positive; default = 4; };
      memoryMiB = mkOption { type = types.ints.positive; default = 8192; };
      diskMiB = mkOption { type = types.ints.positive; default = 32768; };
    };
  };
  secureTerminalType = types.submodule {
    options = {
      enable = mkEnableOption "the Hermes secure terminal";
      backend = mkOption {
        type = types.enum [ "podman" "gondolin" ];
        default = "podman";
      };
      image = mkOption { type = types.str; default = "docker.io/nikolaik/python-nodejs:python3.11-nodejs20"; };
      cpus = mkOption { type = types.ints.positive; default = 2; };
      memoryMiB = mkOption { type = types.ints.positive; default = 4096; };
      diskMiB = mkOption { type = types.ints.positive; default = 20480; };
      network = mkOption { type = types.bool; default = true; };
      lifetimeSeconds = mkOption { type = types.ints.positive; default = 900; };
      defaultTemplate = mkOption { type = types.str; default = "project"; };
      allowedPairs = mkOption {
        type = types.listOf (types.submodule {
          options = {
            asset = mkOption { type = types.str; };
            template = mkOption { type = types.str; };
          };
        });
        default = [
          { asset = "general"; template = "project"; }
          { asset = "general"; template = "research"; }
          { asset = "general"; template = "offline"; }
          { asset = "minimal"; template = "offline"; }
        ];
      };
      maximum = mkOption {
        type = types.submodule {
          options = {
            networkBundles = mkOption { type = types.listOf types.str; default = [ ]; };
            credentialCapabilities = mkOption { type = types.listOf types.str; default = [ ]; };
            resources = mkOption { type = resourceType; default = { }; };
            grantScopes = mkOption { type = types.listOf types.str; default = [ "once" "task" ]; };
          };
        };
        default = { };
      };
      worklanes = mkOption { type = types.attrsOf types.attrs; default = { }; };
      workspaceHandoff = mkOption {
        type = types.submodule {
          options = {
            enable = mkEnableOption "Hermes workspace handoffs";
            handoffLimits = mkOption { type = types.attrsOf types.ints.positive; default = { }; };
          };
        };
        default = { };
      };
      projectMaterializationLimits = mkOption { type = types.attrsOf types.ints.positive; default = { }; };
    };
  };
  secretType = types.submodule {
    options = {
      env = mkOption { type = pathType; default = null; };
      githubPat = mkOption { type = pathType; default = null; };
      tailscale = mkOption { type = pathType; default = null; };
    };
  };
  projectType = types.submodule {
    options = {
      name = mkOption { type = types.str; default = "project"; };
      title = mkOption { type = types.str; default = "Project"; };
      board = mkOption { type = types.str; default = "project"; };
      repository = mkOption { type = types.nullOr types.str; default = null; };
      defaultRef = mkOption { type = types.str; default = "main"; };
      directory = mkOption { type = types.str; default = "/home/hermes/workspace/projects/project"; };
      legacyDirectory = mkOption { type = types.str; default = "/home/hermes/workspace/project"; };
    };
  };
in
rec {
  inherit settingsType secureTerminalType secretType projectType;
  profileOptions = {
    enable = mkEnableOption "this Hermes profile";
    instance = mkOption { type = types.str; };
    userName = mkOption { type = types.str; default = "hermes"; };
    uid = mkOption { type = types.nullOr types.int; default = null; };
    settings = mkOption { type = settingsType; default = { instance = "default"; }; };
    secrets = mkOption { type = secretType; default = { }; };
    project = mkOption { type = projectType; default = { }; };
    secureTerminal = mkOption { type = secureTerminalType; default = { }; };
  };
  profileType = types.submodule { options = profileOptions; };
}
