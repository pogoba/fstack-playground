# Nix packaging for the F-Stack development tree.
#
# Via the flake:      nix build .#fstack  (see ../flake.nix)
# Legacy nix-build:   nix-build nix/ -A all
# Individual targets: nix-build nix/ -A dpdk
#                     nix-build nix/ -A fstack          (libfstack.a + examples + syscall adapter)
#                     nix-build nix/ -A fstack-iperf    (heatheart3 fork — vanilla iperf3, see README)
#                     nix-build nix/ -A iperf-fstack    (guhaoyu2005 fork — vanilla iperf3, see README)
#                     nix-build nix/ -A iperf3-fstack   (iperf3 wrapped with libff_syscall.so LD_PRELOAD)
{
  pkgs ? import <nixpkgs> { },
  # Source roots; overridden by the flake with its path inputs.
  fstackRoot ? ../f-stack,
  fstackIperfRoot ? ../Fstack-iperf,
  iperfFstackRoot ? ../iperf_fstack,
}:

let
  inherit (pkgs) lib stdenv;

  # Source of the bundled (F-Stack-patched) DPDK. F-Stack requires its own
  # DPDK tree, not upstream.
  dpdkSrc = builtins.path {
    path = fstackRoot + "/dpdk";
    name = "f-stack-dpdk-src";
  };

  # F-Stack tree without the heavyweight parts that the lib/example/adapter
  # build does not need (bundled dpdk is built separately; app/ contains
  # nginx/redis sources; .git is 177M).
  fstackSrc = builtins.path {
    path = fstackRoot;
    name = "f-stack-src";
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString fstackRoot + "/") path;
      in
      !(lib.elem rel [
        ".git"
        "dpdk"
        "app"
        "doc"
        "docs"
        "tests"
      ]);
  };

  mkIperfFork =
    pname: srcRoot:
    stdenv.mkDerivation {
      inherit pname;
      version = "3-fork-unstable";
      src = builtins.path {
        path = srcRoot;
        name = "${pname}-src";
        filter = path: type: baseNameOf path != ".git";
      };
      buildInputs = [
        pkgs.openssl
        pkgs.lksctp-tools
      ];
      configureFlags = [ "--with-openssl=${lib.getDev pkgs.openssl}" ];
      enableParallelBuilding = true;
      meta.mainProgram = "iperf3";
    };

  dpdk = pkgs.callPackage ./dpdk-fstack.nix { src = dpdkSrc; };

  fstack = pkgs.callPackage ./fstack.nix {
    src = fstackSrc;
    dpdk-fstack = dpdk;
  };

  fstack-iperf = mkIperfFork "fstack-iperf" fstackIperfRoot;
  iperf-fstack = mkIperfFork "iperf-fstack" iperfFstackRoot;

  # Run an unmodified iperf3 on top of F-Stack via the syscall-hijack adapter.
  # Requires a running `fstack` instance (see f-stack/adapter/syscall/README.md):
  #   fstack --conf /etc/f-stack.conf --proc-type=primary &
  #   iperf3-fstack -s
  iperf3-fstack = pkgs.writeShellScriptBin "iperf3-fstack" ''
    export LD_PRELOAD=${fstack}/lib/libff_syscall.so
    exec ${lib.getExe fstack-iperf} "$@"
  '';

in
rec {
  inherit
    dpdk
    fstack
    fstack-iperf
    iperf-fstack
    iperf3-fstack
    ;

  all = pkgs.symlinkJoin {
    name = "fstack-development-all";
    paths = [
      dpdk
      fstack
      fstack-iperf
      iperf-fstack
      iperf3-fstack
    ];
  };
}
