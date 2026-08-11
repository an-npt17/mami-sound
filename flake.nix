{
  description = "Plant sensor live system: GUI sonification + Raspberry Pi sensor streamer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            name = "plant-sensor-dev";
            packages = with pkgs; [
              zig
              zls
              alsa-utils # aplay, for sensor-ui audio
            ];
          };
        }
      );
    };
}
