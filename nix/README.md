# Nix packaging for the F-Stack development tree

## Packages

```
nix build .#dpdk           # F-Stack's bundled, patched DPDK 24.11.6
nix build .#fstack         # libfstack.a + headers + examples + syscall adapter
nix build .#fstack-iperf   # heatheart3/Fstack-iperf  (vanilla iperf 3.17.1+, see below)
nix build .#iperf-fstack   # guhaoyu2005/iperf_fstack (vanilla iperf 3.11, see below)
nix build .#iperf3-fstack  # iperf3 wrapped with LD_PRELOAD=libff_syscall.so
nix build .#all            # everything, symlink-joined (also the default package)
```

`nix-build nix/ -A <target>` still works as a flakeless fallback.

`nix develop` drops you into a shell with the packaged DPDK on
`PKG_CONFIG_PATH` and `FF_PATH` set, so `make -C f-stack/lib` works directly
for iterating on libfstack.

## Flake layout

The three source trees are `github:*` inputs pinned to the exact revs the
local checkouts are at (f-stack: `origin/dev`; the iperf forks: their
masters). Consequences:

- **Local modifications to the checkouts are NOT picked up by `nix build`.**
  Carry fixes as patch files in `nix/patches/` (see
  `ff_config-log-dir-non-const.patch`), or push the commits and bump the rev
  in the flake.nix input URL.
- The legacy `nix-build nix/` path still builds from the local checkouts —
  keep them at the pinned revs (plus patches) if the two are expected to
  agree.

nixpkgs is pinned to the same rev as the system registry pin (see
`nix registry list`) so flake and legacy builds share store paths; bump it
together with the system.

## Important finding about the two iperf forks

Both checked-out iperf forks contain **no F-Stack modifications at all**:

- `Fstack-iperf` (heatheart3) master = upstream esnet/iperf `7679199` ("Regen.",
  iperf 3.17.1+), **0 commits ahead**, 254 behind upstream master.
- `iperf_fstack` (guhaoyu2005) master = upstream esnet/iperf `6cdcde8`
  (iperf 3.11), **0 commits ahead**, 471 behind upstream master.

Verified via the GitHub compare API (`ahead_by: 0` for both). They are plain
iperf3 and build as such; nothing in them links against libfstack.

The working route to "iperf over F-Stack" is therefore F-Stack's
`adapter/syscall` LD_PRELOAD hook (`libff_syscall.so`), which hijacks
socket/epoll syscalls of an *unmodified* binary. That is what the
`iperf3-fstack` wrapper does.

## Running iperf over F-Stack (requires root, hugepages, a DPDK-capable NIC)

```sh
# 1. hugepages + NIC binding (vfio-pci; igb_uio kmod is not built, see below)
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
modprobe vfio-pci
result/bin/dpdk-devbind.py --bind=vfio-pci <pci-id>

# 2. start the F-Stack instance process (config: f-stack/config.ini)
result/bin/fstack --conf /etc/f-stack.conf --proc-type=primary --proc-id=0 &

# 3. run iperf3 hooked onto that instance
result/bin/iperf3-fstack -s
```

`ff_helloworld`, `ff_helloworld_epoll` and the `ff_helloworld_stack*` demos are
installed as smoke tests for the same setup.

LD_PRELOAD mode requirements (verified with iperf 3.17):

- The adapter is built with `FF_PRELOAD_SUPPORT_SELECT=1` /
  `FF_KERNEL_MAX_FD_SELECT=128` so select()-based apps work: app-visible
  F-Stack fds are `freebsd_fd + 128` and must stay below FD_SETSIZE (1024).
- Therefore `fd_reserve` in the f-stack config MUST be small (128, not the
  upstream default 1024) — FreeBSD fds start at `fd_reserve`, and
  1024 + 128 ≥ FD_SETSIZE makes glibc's fortified FD_SET abort.
- Connecting to the instance's *own* IP (loopback through F-Stack) currently
  fails with EPERM on this dev branch; test against a real peer instead.

Performance (measured on the dual-port BCM57416 DAC rig, 2026-06-11):

- **`pkt_tx_delay=0`** in the f-stack config is required for TCP throughput:
  the upstream default of 100 (µs TX batching) inflates the ACK-clock RTT
  and caps a single stream at ~3.1 Gbit/s. With 0 (plus `iperf3 -l 1M`):
  **9.29 Gbit/s** — TCP payload line rate on 10GbE at 1500 MTU.
- The adapter's select() re-poll loop is throttled by 20µs
  (`ff-hook-select-backoff.patch`); unthrottled, the instances burn ~80% of
  their core servicing kern_select instead of moving packets.
- The `Retr`/`Cwnd` columns in iperf output are garbage (Linux vs FreeBSD
  `TCP_INFO` struct mismatch); trust the Transfer/Bitrate columns.

## Notes / deviations from upstream build

- F-Stack executables are linked `-no-pie`: F-Stack's FreeBSD `link_elf` code
  registers the running executable as the "kernel" linker file with
  `ef->address = 0` and resolves its linker-set symbols
  (`__start_set_modmetadata_set`, in `.dynsym` due to DPDK's
  `-Wl,--export-dynamic`) from the dynamic symbol table — with a PIE binary
  those are pre-relocation vaddrs and `linker_preload` segfaults during
  `ff_init`. Affects any distro whose gcc defaults to PIE (Debian, Ubuntu,
  Fedora, NixOS); a proper upstream fix would derive `ef->address` from the
  actual load base (`dl_iterate_phdr` / `getauxval(AT_PHDR)`) in
  `link_elf_init`.

- The bundled DPDK is built with `-Dplatform=generic` for reproducibility;
  override `mesonFlags` with `native` for production performance.
- Kernel modules (`igb_uio`) are **not** built: F-Stack re-adds igb_uio and
  unconditionally probes `/lib/modules/$(uname -r)/build` during `meson setup`;
  the derivation restores upstream's `enable_kmods` gating. Use `vfio-pci`, or
  extend `dpdk-fstack.nix` with `-Denable_kmods=true` plus
  `-Dkernel_dir=${linuxPackages.kernel.dev}/lib/modules/<ver>/build`.
- `fstack` builds `lib/` (libfstack.a), `example/` (helloworld link check) and
  `adapter/syscall` (fstack instance binary, libff_syscall.so, demos) in one
  derivation, because the adapter/example Makefiles expect the source-tree
  layout (`-I$FF_PATH/lib`, `-L$FF_PATH/lib`).
