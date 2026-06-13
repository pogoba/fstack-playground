# F-Stack: libfstack.a (FreeBSD 13 user-space TCP/IP stack on DPDK) plus the
# helloworld examples and the syscall-hijack adapter (libff_syscall.so), which
# together verify that the library links correctly.
{
  stdenv,
  lib,
  src,
  dpdk-fstack,
  pkg-config,
  gawk,
  openssl,
  numactl,
  zlib,
  libpcap,
  # Compile libfstack.a with DWARF (-g) and skip stripping, for gdb against
  # live processes. Disable for benchmark builds with the exact upstream
  # codegen flags (see `debug` in nix/default.nix).
  withDebug ? true,
}:

stdenv.mkDerivation {
  pname = "fstack";
  version = "1.26";
  inherit src;

  patches = [
    # free()d in ff_config.c but declared const; rejected by gcc 14 -Werror.
    ./patches/ff_config-log-dir-non-const.patch
    # ff_hook_select sets have_ff_exceptfd when scanning writefds (and vice
    # versa), so write-only select() forwards NULL writefds to the instance
    # and never reports writability (e.g. nonblocking connect completion).
    ./patches/ff-hook-select-writefd-flag-swap.patch
    # The 14.0+ rebase wrapped callout_tick's softclock dispatch in
    # #ifndef FSTACK, disabling all TCP timers (RTO, delayed ACK, persist);
    # connections stall as soon as progress depends on a timer.
    ./patches/ff-callout-tick-dispatch-softclock.patch
    # The sbintime->tick compat macro ignores C_ABSOLUTE: FreeBSD 14+'s
    # unified TCP timer passes absolute sbinuptime() deadlines, which were
    # scheduled aeons in the future instead of relative to now.
    ./patches/ff-callout-sbt-absolute.patch
    # callout_when was an empty stub (ff_stub_14_extra.c), so
    # tcp_timer_activate never armed t_timers[] and no TCP timer was ever
    # scheduled in the first place.
    ./patches/ff-callout-when-implement.patch
    # Throttle ff_hook_select re-polling (20us): the unthrottled retry loop
    # consumes ~80% of the instance core in kern_select evaluations and
    # starves packet processing (profiled: 3.15 Gbit/s ceiling).
    ./patches/ff-hook-select-backoff.patch
    # Under `make -j`, lib objects race the machine_include/ staging and the
    # awk-generated *_if.h headers (all sibling prerequisites of libfstack.a):
    # kern_*.o fail with "machine/endian.h: No such file or directory" on
    # hosts that lose the race.
    ./patches/ff-lib-objs-order-after-machine-includes.patch
    # Enable hardware LRO (upstream leaves it '#if 0'): RX-side mirror of
    # TSO, collapses the receiver's dominant per-packet costs.
    ./patches/ff-enable-lro.patch
    # ff_pump(): run a single stack-loop iteration, so sequential native
    # apps can drive the stack wherever they would otherwise block,
    # instead of inverting into an ff_run() callback.
    ./patches/ff-add-ff-pump.patch
    # [vdevN] iface= emits an eth_vhost vdev (vhost-user backend, creates
    # the socket) instead of the hardcoded virtio_user (frontend); two
    # F-Stack instances can then pair up over one unix socket with no
    # physical NIC. Also passes --single-file-segments, which virtio_user
    # needs to share its memory with the backend.
    ./patches/ff-vdev-eth-vhost.patch
    # net.inet.tcp.delack_segs (default 2 = stock "ACK every other
    # segment"): make the receiver's delayed-ACK threshold count-based and
    # tunable, so the sender's per-ACK ffn_select wakeups can be throttled.
    ./patches/ff-tcp-delack-segs.patch
  ];

  postPatch = ''
    # The fstack instance binary's link rule bypasses CFLAGS, so the -no-pie
    # below (see buildPhase) would not reach it.
    substituteInPlace adapter/syscall/Makefile \
      --replace-fail 'cc -o $@ $^ ''${FSTACK_LIBS}' 'cc ''${CFLAGS} -o $@ $^ ''${FSTACK_LIBS}'
  '';

  nativeBuildInputs = [
    pkg-config
    gawk
  ];

  buildInputs = [
    dpdk-fstack
    openssl
    numactl
    zlib
    libpcap
  ];

  enableParallelBuilding = true;

  # keep the -g DWARF (see DEBUG= below) in libfstack.a: the FreeBSD stack
  # is regularly debugged with gdb against live processes
  dontStrip = withDebug;

  buildPhase = ''
    runHook preBuild

    export FF_PATH=$PWD

    # FF_IPFW/FF_NETGRAPH off: ipfw_chk costs ~4-6% of the instance core on
    # every packet (profiled on both ends of the iperf rig); neither is
    # needed for a plain TCP/UDP stack.
    make -C lib -j$NIX_BUILD_CORES FF_IPFW= FF_NETGRAPH= \
      ${lib.optionalString withDebug ''DEBUG="-g -O2 -Wno-format-truncation -Wno-error=maybe-uninitialized -Wno-error=strict-aliasing"''}

    # The example/adapter Makefiles expect ff_*.h preinstalled in
    # /usr/local/include; inject the in-tree header path via the environment
    # (their `CFLAGS +=` appends to it).
    #
    # -no-pie: F-Stack's FreeBSD link_elf code resolves its own linker-set
    # symbols (__start_set_modmetadata_set etc.) from .dynsym with
    # ef->address = 0, assuming link addr == load addr. nixpkgs gcc defaults
    # to PIE, which breaks that assumption and makes linker_preload segfault
    # on the unrelocated address during ff_init.
    CFLAGS="-I$FF_PATH/lib -no-pie" make -C example
    # serial: the adapter Makefile's `example` target races against
    # libff_syscall.so under -j
    #
    # FF_PRELOAD_SUPPORT_SELECT: hook select() and keep F-Stack fds below
    # FD_SETSIZE; without it, select()-based apps (iperf3) abort in glibc's
    # fortify FD_SET bounds check because F-Stack fds start above
    # RLIMIT_NOFILE. Kernel fds are then capped at FF_KERNEL_MAX_FD_SELECT.
    # (Implies FF_USE_THREAD_STRUCT_HANDLE; both the fstack instance and
    # libff_syscall.so are built here with the same flags, keeping the
    # shared-memory layout consistent.)
    CFLAGS="-I$FF_PATH/lib -no-pie" \
      FF_PRELOAD_SUPPORT_SELECT=1 FF_KERNEL_MAX_FD_SELECT=128 \
      make -C adapter/syscall

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/bin $out/etc
    make -C lib install PREFIX=$out F-STACK_CONF=$out/etc/f-stack.conf

    # helloworld examples (link check for ff_api / ff_epoll)
    install -m755 example/helloworld $out/bin/ff_helloworld
    install -m755 example/helloworld_epoll $out/bin/ff_helloworld_epoll
    if [ -f example/helloworld_zc ]; then
      install -m755 example/helloworld_zc $out/bin/ff_helloworld_zc
    fi

    # syscall adapter: F-Stack instance + LD_PRELOAD hook library + demos
    install -m755 adapter/syscall/fstack $out/bin/fstack
    install -m644 adapter/syscall/libff_syscall.so $out/lib/
    for demo in adapter/syscall/helloworld_stack*; do
      [ -x "$demo" ] && install -m755 "$demo" $out/bin/ff_$(basename "$demo")
    done

    runHook postInstall
  '';

  meta = {
    description = "F-Stack user-space network framework based on DPDK";
    homepage = "https://www.f-stack.org";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
