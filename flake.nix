{
  description = "Secure Hermes Agent infrastructure and Nix integration";

  nixConfig = {
    extra-substituters = [ "https://cache.garnix.io" "https://nix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.7.20";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";


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
      ];
    };
}
