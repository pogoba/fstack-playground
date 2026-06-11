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

  buildPhase = ''
    runHook preBuild

    export FF_PATH=$PWD

    # FF_IPFW/FF_NETGRAPH off: ipfw_chk costs ~4-6% of the instance core on
    # every packet (profiled on both ends of the iperf rig); neither is
    # needed for a plain TCP/UDP stack.
    make -C lib -j$NIX_BUILD_CORES FF_IPFW= FF_NETGRAPH=

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
