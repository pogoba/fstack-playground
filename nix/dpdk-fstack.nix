# F-Stack's bundled DPDK (24.11.6 with F-Stack modifications).
# Kernel modules (igb_uio) are not built; bind NICs with vfio-pci, or extend
# this with -Denable_kmods=true and -Dkernel_dir=${kernel.dev} if igb_uio is
# needed.
{
  stdenv,
  lib,
  src,
  meson,
  ninja,
  pkg-config,
  python3,
  numactl,
  libpcap,
  zlib,
  openssl,
  libnl,
}:

stdenv.mkDerivation {
  pname = "dpdk-fstack";
  version = "24.11.6";
  inherit src;

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    python3
    python3.pkgs.pyelftools
  ];

  buildInputs = [
    openssl
    python3
  ];

  # Static consumers (libfstack and apps linking it) resolve these via
  # `pkg-config --static --libs libdpdk`.
  propagatedBuildInputs = [
    numactl
    libpcap
    zlib
    # libpcap.pc pulls in libnl-genl-3.0 when resolved with --static
    libnl
  ];

  postPatch = ''
    patchShebangs config/arm buildtools

    # F-Stack re-adds igb_uio and probes /lib/modules/$(uname -r)/build during
    # meson setup even with -Denable_kmods=false; restore upstream's gating so
    # the sandboxed build does not touch the host kernel tree.
    printf '%s\n' \
      "if not get_option('enable_kmods')" \
      "    subdir_done()" \
      "endif" \
      | cat - kernel/linux/meson.build > kernel/linux/meson.build.tmp
    mv kernel/linux/meson.build.tmp kernel/linux/meson.build
  '';

  mesonFlags = [
    "-Denable_kmods=false"
    "-Dtests=false"
    "-Denable_docs=false"
    "-Ddefault_library=static"
    # Reproducible baseline instead of -march=native; override for production
    # performance tuning.
    "-Dplatform=generic"
  ];

  meta = {
    description = "DPDK bundled with F-Stack (F-Stack-patched 24.11.6)";
    license = with lib.licenses; [
      lgpl21
      gpl2Only
      bsd2
    ];
    platforms = lib.platforms.linux;
  };
}
