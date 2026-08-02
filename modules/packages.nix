{ self, inputs, ... }:
{
  perSystem =
    { pkgs, lib, system, ... }:
    let
      hasHermes = lib.hasAttrByPath [ system "default" ] inputs.hermes-agent.packages;
      hasCodex = lib.hasAttrByPath [ system "codex" ] inputs.llm-agents.packages;
      supportsBroker = system != "x86_64-darwin";

      hermesBase =
        if hasHermes then
          inputs.hermes-agent.packages.${system}.default.override {
            extraDependencyGroups = [ "messaging" ];
          }
        else
          null;

      hermesAgentPatched = lib.optionalAttrs hasHermes {
        hermes-agent-patched = pkgs.callPackage (self + "/pkgs/by-name/hermes-agent-patched/package.nix") {
          hermesAgent = hermesBase;
          src = inputs.hermes-agent;
        };
      };
      hermesCodexWorkerLane = pkgs.callPackage (
        self + "/pkgs/by-name/hermes-codex-worker-lane/package.nix"
      ) { };
      hermesSandboxAccess = pkgs.callPackage (self + "/pkgs/by-name/hermes-sandbox-access/package.nix") { };
      gondolinBrokerEffect = lib.optionalAttrs supportsBroker {
        gondolin-broker-effect = pkgs.callPackage (
          self + "/pkgs/by-name/gondolin-broker-effect/package.nix"
        ) { };
      };
      hermesImage = lib.optionalAttrs (hasHermes && pkgs.stdenv.hostPlatform.isLinux) {
        hermes-agent-image = self.lib.mkHermesImage {
          inherit pkgs system;
          hermesAgent = hermesBase;
          includeCodex = hasCodex;
        };
      };
    in
    {
      packages = hermesAgentPatched // gondolinBrokerEffect // hermesImage // {
        "hermes-codex-worker-lane" = hermesCodexWorkerLane;
        "hermes-sandbox-access" = hermesSandboxAccess;
      };

      checks = lib.optionalAttrs hasHermes {
        hermes-agent-patched = pkgs.callPackage (
          self + "/pkgs/by-name/hermes-agent-patched/check.nix"
        ) {
          patchedHermes = hermesAgentPatched.hermes-agent-patched;
          codexWorkerLane = hermesCodexWorkerLane;
          sandboxAccess = hermesSandboxAccess;
        };
      } // lib.optionalAttrs supportsBroker {
        gondolin-broker-effect = gondolinBrokerEffect.gondolin-broker-effect;
      };
    };
}
