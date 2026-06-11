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

    make -C lib -j$NIX_BUILD_CORES

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
    CFLAGS="-I$FF_PATH/lib -no-pie" make -C adapter/syscall

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
