{
  description = "Dev shell for nvidia-cuda-installer-for-debian: shellcheck and the hermetic test toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bash
            shellcheck
            util-linux   # flock, used by the installer's execution lock
            coreutils
            findutils
            gawk
            gnugrep
            gnused
            diffutils
          ];
          shellHook = ''
            umask 022
            echo "nvidia-cuda-installer dev shell: $(shellcheck --version | sed -n 2p)"
          '';
        };
      });
    };
}
