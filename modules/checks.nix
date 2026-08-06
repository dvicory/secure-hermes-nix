{ self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      settingsOptions = self.lib.settings;
      network = self.lib.network;
      catalogue = self.lib.catalogue;
      evalSettings = value:
        lib.evalModules {
          modules = [
            {
              options.settings = lib.mkOption {
                type = lib.types.submodule { options = settingsOptions; };
              };
              config.settings = value;
            }
          ];
        };
      validSettings = (evalSettings {
        instance = "check";
        workerLanes.research = {
          description = "bounded research";
          runtime = "hermes";
          policy.approvalPolicy = "never";
          workspace.projectMode = "none";
          workspace.inputs = { };
        };
        boards.main = {
          allowedLanes = [ "research" ];
        };
      }).config.settings;
      validCatalogue = catalogue.resolve validSettings;
      invalidUpstream = builtins.tryEval (
        builtins.deepSeq (
          catalogue.resolve (validSettings // {
            projectSources.example = {
              type = "git";
              upstream = "https://token@example.invalid/repository.git";
            };
          })
        ) true
      );
      invalidHostname = builtins.tryEval (
        builtins.deepSeq (network.httpsExact "not a hostname") true
      );
    in
    {
      checks.hermes-library =
        assert validCatalogue.instance == "check";
        assert builtins.stringLength validCatalogue.revision == 64;
        assert !invalidUpstream.success;
        assert !invalidHostname.success;
        pkgs.runCommand "hermes-library" { } "touch $out";
    };
}
