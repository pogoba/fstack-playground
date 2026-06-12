{
  description = "F-Stack + bundled DPDK + iperf-over-F-Stack packaging for the local development checkouts";

  inputs = {
    # Pinned to the same rev as the system nixpkgs (see `nix registry list`,
    # "system flake:nixpkgs") so flake builds reuse the store paths already
    # produced via `nix-build nix/`. Bump together with the system.
    nixpkgs.url = "github:NixOS/nixpkgs/ce56a0cf964598eaecc6fbd573b83c3c041823e8";

    # Pinned to the exact revs the local checkouts are at (f-stack: origin/dev;
    # the iperf forks: their masters, which are vanilla upstream iperf3 — see
    # nix/README.md). Bump the rev in the URL to update; local modifications to
    # the checkouts are NOT picked up — carry them as patches in nix/patches/.
    f-stack = {
      url = "github:F-Stack/f-stack/c1a76b0ba36c53269913cd805d83a536cd8f64bc";
      flake = false;
    };
    fstack-iperf-src = {
      url = "github:heatheart3/Fstack-iperf/7679199ec99c5db194c554b7b11066d347891735";
      flake = false;
    };
    iperf-fstack-src = {
      url = "github:guhaoyu2005/iperf_fstack/6cdcde886fa1400dd367c1da54da13ab4f4c5ea7";
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

      # Same package set without DWARF/dontStrip in libfstack.a and the
      # native iperf (exact upstream codegen flags) — for benchmark builds.
      packagesRelease = import ./nix {
        inherit pkgs;
        debug = false;
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
          iperf-fstack-native
          iperf3-fstack
          all
          ;
        default = packages.all;
        fstack-release = packagesRelease.fstack;
        iperf-fstack-native-release = packagesRelease.iperf-fstack-native;
        iperf3-fstack-release = packagesRelease.iperf3-fstack;
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
