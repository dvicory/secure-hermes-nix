{
  description = "Secure Hermes Agent infrastructure and Nix integration";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.7.20";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";

    gondolin-nix = {
      url = "github:dvicory/gondolin-nix/secure-terminal-v3";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
  };

  outputs = inputs@{ self, flake-parts, systems, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      flake = {
        lib = import ./modules/lib { inherit inputs self; };
        nixosModules.hermes = import ./modules/nixos/hermes.nix { inherit inputs self; };
        homeManagerModules.hermes = import ./modules/home-manager/hermes.nix {
          inherit inputs self;
        };
      };

      imports = [
        ./modules/packages.nix
        ./modules/checks.nix
        ./modules/tests/secure-terminal-policy.nix
        ./modules/tests/hermes-worker-lanes.nix
      ];
    };
}
