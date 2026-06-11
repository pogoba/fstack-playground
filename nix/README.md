# Nix packaging for the F-Stack development tree

## Packages

```
nix-build nix/ -A dpdk           # F-Stack's bundled, patched DPDK 24.11.6
nix-build nix/ -A fstack         # libfstack.a + headers + examples + syscall adapter
nix-build nix/ -A fstack-iperf   # heatheart3/Fstack-iperf  (vanilla iperf 3.17.1+, see below)
nix-build nix/ -A iperf-fstack   # guhaoyu2005/iperf_fstack (vanilla iperf 3.11, see below)
nix-build nix/ -A iperf3-fstack  # iperf3 wrapped with LD_PRELOAD=libff_syscall.so
nix-build nix/ -A all            # everything, symlink-joined
```

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

## Notes / deviations from upstream build

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
