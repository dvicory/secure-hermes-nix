{ inputs, self }:
let
  lib = inputs.nixpkgs.lib;
in
{
  settings = import ./settings.nix { inherit lib; };
  catalogue = import ./catalogue.nix { inherit lib; };
  options = import ./options.nix { inherit lib; };
  network = import ./network-dsl.nix { inherit lib; };
  networkBundles = import ./network-bundles.nix { net = import ./network-dsl.nix { inherit lib; }; };
  policy = import ./policy.nix { };
  guestAssets = import ./guest-assets.nix { inherit inputs; };
  mkHermesImage = import ./image.nix { inherit inputs self; };
}
