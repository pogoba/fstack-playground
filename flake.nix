{
  description = "F-Stack + bundled DPDK + iperf-over-F-Stack packaging for the local development checkouts";

  inputs = {
    # Pinned to the same rev as the system nixpkgs (see `nix registry list`,
    # "system flake:nixpkgs") so flake builds reuse the store paths already
    # produced via `nix-build nix/`. Bump together with the system.
    nixpkgs.url = "github:NixOS/nixpkgs/ce56a0cf964598eaecc6fbd573b83c3c041823e8";

    # The three sibling checkouts as git inputs: only tracked files are
    # fetched (no .git, no untracked junk), each tree is cached separately,
    # and dirty worktrees are supported. Caveats: untracked new files in the
    # checkouts are invisible to the build (`git add` them), and while a
    # checkout is dirty nix warns that it cannot update flake.lock (harmless;
    # `nix flake lock --allow-dirty-locks` to silence).
    f-stack = {
      url = "git+file:///home/okelmann/fstack-development/f-stack";
      flake = false;
    };
    fstack-iperf-src = {
      url = "git+file:///home/okelmann/fstack-development/Fstack-iperf";
      flake = false;
    };
    iperf-fstack-src = {
      url = "git+file:///home/okelmann/fstack-development/iperf_fstack";
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
