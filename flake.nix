{
  description = "F-Stack + bundled DPDK + iperf-over-F-Stack packaging for the local development checkouts";

  inputs = {
    # Resolved via the system flake registry, which pins the system nixpkgs —
    # keeps the flake builds bit-identical with `nix-build nix/`.
    nixpkgs.url = "flake:nixpkgs";

    # The three sibling checkouts as relative path inputs. self stays tiny
    # (only the tracked scaffolding); each tree is fetched & locked separately,
    # so editing one does not re-copy the others.
    f-stack = {
      url = "path:./f-stack";
      flake = false;
    };
    fstack-iperf-src = {
      url = "path:./Fstack-iperf";
      flake = false;
    };
    iperf-fstack-src = {
      url = "path:./iperf_fstack";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      packages = import ./nix {
        inherit pkgs;
        fstackRoot = inputs.f-stack.outPath;
        fstackIperfRoot = inputs.fstack-iperf-src.outPath;
        iperfFstackRoot = inputs.iperf-fstack-src.outPath;
      };
    in
    {
      packages.${system} = {
        inherit (packages)
          dpdk
          fstack
          fstack-iperf
          iperf-fstack
          iperf3-fstack
          all
          ;
        default = packages.all;
      };

      # Shell for hacking on f-stack/lib manually:
      #   nix develop
      #   export FF_PATH=$PWD/f-stack && make -C f-stack/lib
      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ packages.fstack ];
        shellHook = ''
          export FF_PATH=$PWD/f-stack
        '';
      };
    };
}
