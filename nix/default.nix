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
  # Build libfstack.a and iperf-fstack-native with DWARF (-g, unstripped)
  # for gdb against live processes. Disable for benchmark builds with the
  # exact upstream codegen flags:
  #   nix-build nix/ -A iperf-fstack-native --arg debug false
  #   nix build .#iperf-fstack-native-release   (see ../flake.nix)
  debug ? true,
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
    pname: srcRoot: patches:
    stdenv.mkDerivation {
      inherit pname patches;
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
    withDebug = debug;
  };

  fstack-iperf = mkIperfFork "fstack-iperf" fstackIperfRoot [
    # libff_syscall.so hooks select() but not poll(); unhooked poll on an
    # F-Stack fd fakes connect completion and iperf3 then writes to a
    # still-connecting socket (ENOTCONN).
    ./patches/iperf-timeout-connect-select.patch
  ];
  iperf-fstack = mkIperfFork "iperf-fstack" iperfFstackRoot [
    # same select()-instead-of-poll() + always-nonblocking-connect fix,
    # ported to this fork's iperf 3.11 base
    ./patches/iperf311-timeout-connect-select.patch
  ];

  # iperf3 compiled natively against ff_api: the app embeds the F-Stack
  # instance (no LD_PRELOAD adapter, no IPC, no shm copies) and pumps the
  # stack via ff_pump() wherever it would block. Runs as the DPDK primary:
  #   sudo FF_CONF=$PWD/config.ini ./result/bin/iperf3 -s -B <addr>
  # TCP only for now (the UDP connect handshake still does a raw blocking
  # read).
  iperf-fstack-native = stdenv.mkDerivation {
    pname = "iperf-fstack-native";
    version = "3.11-ff-native";
    src = builtins.path {
      path = iperfFstackRoot;
      name = "iperf-fstack-native-src";
      filter = path: type: baseNameOf path != ".git";
    };
    patches = [
      ./patches/iperf311-timeout-connect-select.patch
      ./patches/iperf311-ff-native.patch
      # Zero-copy receive path (env FF_ZC_RECV=1): the TCP server drains
      # each stream via ff_recv_mbuf + ff_mbuf_free instead of a copying
      # read. A/B-toggleable in one binary.
      ./patches/iperf311-ff-zc-recv.patch
      # Zero-copy send path (env FF_ZC_SEND=1): the sender transmits via
      # ff_zc_mbuf_ext + ff_zc_send (external-buffer mbuf, no copy) instead
      # of a copying write. A/B-toggleable in one binary.
      ./patches/iperf311-ff-zc-send.patch
    ];
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.openssl
      pkgs.lksctp-tools
      fstack
      dpdk
      pkgs.numactl
      pkgs.zlib
      pkgs.libpcap
    ];
    configureFlags = [
      "--with-openssl=${lib.getDev pkgs.openssl}"
      "--disable-shared"
      "--enable-static"
    ];
    NIX_CFLAGS_COMPILE = "-DFF_NATIVE -I${fstack}/include";
    # keep DWARF (autotools builds with -g -O2 anyway): the ff-native port
    # is regularly debugged with gdb against live processes
    dontStrip = debug;
    preConfigure = ''
      # libtool reorders bare -l/-l: arguments out of --whole-archive
      # groups, breaking DPDK's constructor-based PMD registration; armor
      # every archive reference as -Wl,... so libtool passes it verbatim.
      dpdk_libs=$(pkg-config --static --libs libdpdk | sed -e 's/ -l:/ -Wl,-l:/g' -e 's/ -lrte_/ -Wl,-lrte_/g')
      export LIBS="-L${fstack}/lib -Wl,--whole-archive,-lfstack,--no-whole-archive $dpdk_libs -lrt -lm -ldl -lcrypto -lz -pthread -lnuma"
      # -no-pie must survive libtool (link_elf self-introspection breaks
      # under PIE); smuggle it through the compiler driver.
      export CC="gcc -no-pie"
    '';
    enableParallelBuilding = true;
    meta.mainProgram = "iperf3";
  };

  # Run iperf3 on top of F-Stack via the syscall-hijack adapter.
  # Requires a running `fstack` instance (see f-stack/adapter/syscall/README.md):
  #   fstack --conf /etc/f-stack.conf --proc-type=primary &
  #   iperf3-fstack -s
  # Uses the iperf 3.11 fork: iperf >= 3.16 does per-stream worker threads,
  # which the adapter's process-global IPC context cannot serve (worker
  # threads' stream I/O fails and they exit silently -> 0 bytes transferred).
  iperf3-fstack = pkgs.writeShellScriptBin "iperf3-fstack" ''
    export LD_PRELOAD=${fstack}/lib/libff_syscall.so
    exec ${lib.getExe iperf-fstack} "$@"
  '';

in
rec {
  inherit
    dpdk
    fstack
    fstack-iperf
    iperf-fstack
    iperf-fstack-native
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
