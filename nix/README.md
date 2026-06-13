# Nix packaging for the F-Stack development tree

## Packages

```
nix build .#dpdk           # F-Stack's bundled, patched DPDK 24.11.6
nix build .#fstack         # libfstack.a + headers + examples + syscall adapter
nix build .#fstack-iperf   # heatheart3/Fstack-iperf  (vanilla iperf 3.17.1+, see below)
nix build .#iperf-fstack   # guhaoyu2005/iperf_fstack (vanilla iperf 3.11, see below)
nix build .#iperf3-fstack  # iperf3 wrapped with LD_PRELOAD=libff_syscall.so
nix build .#iperf-fstack-native  # iperf3 compiled directly against ff_api (fastest)
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

One-time setup:

```sh
# hugepages + NIC binding (vfio-pci; igb_uio kmod is not built, see below)
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
modprobe vfio-pci
result/bin/dpdk-devbind.py --bind=vfio-pci <pci-id>
```

`ff_helloworld`, `ff_helloworld_epoll` and the `ff_helloworld_stack*` demos are
installed as smoke tests for the same setup.

### Example: dual-port DAC loopback measurement (9.29 Gbit/s)

Setup used: the two ports of a 10G NIC (BCM57416, `0000:c4:00.0` and
`0000:c4:00.1`) connected to each other with a DAC cable, both bound to
vfio-pci. Two independent F-Stack instances run in one DPDK domain — proc 0
owns port 0 (192.168.1.2), proc 1 owns port 1 (192.168.1.3) via per-port
`lcore_list` in `config-dual.ini` (see repo root; the essentials are
`lcore_mask=3`, `port_list=0,1`, `[portN] lcore_list=N`, `fd_reserve=128`,
`pkt_tx_delay=0`). iperf processes pick their instance with `FF_PROC_ID`.

Four terminals, in this order:

```sh
# 1. F-Stack instance for port 0 (192.168.1.2); wait for
#    "Successed to register dpdk interface" (~8s)
sudo ./result/bin/fstack --conf $PWD/config-dual.ini --proc-type=primary --proc-id=0

# 2. F-Stack instance for port 1 (192.168.1.3)
sudo ./result/bin/fstack --conf $PWD/config-dual.ini --proc-type=secondary --proc-id=1

# 3. iperf3 server, attached to the port-1 stack
sudo FF_PROC_ID=1 FF_NB_FSTACK_INSTANCE=2 FF_INITIAL_LCORE_ID=8 \
    ./result/bin/iperf3-fstack -s -B 192.168.1.3

# 4. iperf3 client, attached to the port-0 stack
sudo FF_PROC_ID=0 FF_NB_FSTACK_INSTANCE=2 FF_INITIAL_LCORE_ID=10 \
    ./result/bin/iperf3-fstack -c 192.168.1.3 -t 10 -l 1M
```

Result (2026-06-11, with the patches in `nix/patches/`):

```
[257]   0.00-10.01  sec  10.9 GBytes  9.33 Gbits/sec   sender
[257]   0.00-10.01  sec  10.9 GBytes  9.32 Gbits/sec   receiver
```

Notes:

- `FF_PROC_ID` selects the instance to attach to; `FF_INITIAL_LCORE_ID` is a
  hex CPU mask for the app's EAL thread (8 = core 3, 0x10 = core 4) — keep
  them distinct from each other and from the instance cores (0 and 1, which
  busy-poll at 100%).
- Start order matters: primary instance, secondary instance, server, client.
- "Address already in use" from the server means a previous iperf's listen
  socket leaked into the instance (known adapter limitation on app exit) —
  restart both instances.
- The hook prints `file:ff_hook_syscall.c, ...` debug lines on a tty; that
  is normal.
- F-Stack-internal loopback (connecting to the instance's own IP) does NOT
  work — this example measures real traffic over the cable between two
  separate stacks.

### Example: two hosts, one port each (12.9 Gbit/s on 100G E810)

Each host runs one primary instance in its own DPDK domain; the iperf
processes need no `FF_*` environment variables (defaults attach to proc 0 of
the local domain). The two configs differ only in the `[port0]` section —
the addresses mirror each other:

```ini
# host A: config.ini        # host B: config2.ini
[port0]                     [port0]
addr=192.168.1.2            addr=192.168.1.3
netmask=255.255.255.0       netmask=255.255.255.0
broadcast=192.168.1.255     broadcast=192.168.1.255
gateway=192.168.1.3         gateway=192.168.1.2
```

```sh
# host A (server), two terminals:
sudo ./result/bin/fstack --conf $PWD/config.ini --proc-type=primary --proc-id=0
sudo ./result/bin/iperf3-fstack -s -B 192.168.1.2

# host B (client), two terminals:
sudo ./result/bin/fstack --conf $PWD/config2.ini --proc-type=primary --proc-id=0
sudo ./result/bin/iperf3-fstack -c 192.168.1.2 -t 10 -l 1M
```

Measured 2026-06-11 between two hosts over 100G E810-C (single stream,
single core per stack, 1500 MTU; tso=1 + tx_csum_offoad_skip=0, ipfw-less
build, pcap off):

```
[257]   0.00-10.00  sec  22.4 GBytes  19.2 Gbits/sec   sender
[257]   0.00-10.00  sec  22.4 GBytes  19.2 Gbits/sec   receiver
```

### Example: two hosts, native iperf (no LD_PRELOAD) — 20.9 Gbit/s on one core per host

`iperf-fstack-native` is the iperf 3.11 fork compiled directly against
`ff_api`: the binary **embeds the F-Stack instance** and runs as its own
DPDK primary. There is no separate `fstack` process, no `libff_syscall.so`,
no shared-memory IPC and no extra data copies — application and stack share
one busy-polling core per host. Internally, a new `ff_pump()` F-Stack API
(one stack-loop iteration; `nix/patches/ff-add-ff-pump.patch`) is called
wherever iperf would block, so iperf's sequential code runs unmodified
instead of being rewritten into `ff_run()` callbacks.

Setup per host (same prerequisites as the other examples: hugepages, NIC on
vfio-pci, the per-host configs from the two-host example above):

```sh
# build on EACH host — the repo may be shared (NFS), /nix/store is not:
nix build .#iperf-fstack-native -o result-native
```

Stop any LD_PRELOAD-era processes first (`fstack` instances and preload
iperf servers): the native binary is itself the DPDK primary and conflicts
with another primary in the default DPDK domain.

```sh
# host A (server, 192.168.1.2 / config.ini), ONE process:
sudo FF_CONF=$PWD/config.ini ./result-native/bin/iperf3 -s -B 192.168.1.2

# host B (client, 192.168.1.3 / config2.ini):
sudo FF_CONF=$PWD/config2.ini ./result-native/bin/iperf3 -c 192.168.1.2 -t 10 -l 1M
```

Environment variables (replace the preload-era `FF_*` attach variables):

| Variable       | Default        | Meaning                                  |
|----------------|----------------|------------------------------------------|
| `FF_CONF`      | `./config.ini` | f-stack config for the embedded instance |
| `FF_PROC_TYPE` | `primary`      | DPDK process type                        |
| `FF_PROC_ID`   | `0`            | f-stack proc id (selects port/lcore)     |

Result (2026-06-12, E810 100G, single stream, 1500 MTU):

```
[129]   0.00-10.00  sec  24.3 GBytes  20.9 Gbits/sec   sender
[129]   0.00-10.00  sec  24.3 GBytes  20.9 Gbits/sec   receiver
```

vs 19.2 Gbit/s for the LD_PRELOAD pair — +9% throughput at **half the CPU**
(one core/host instead of two), i.e. per-core throughput roughly doubles.
This deployment model matches what F-Stack upstream intends for production
apps (the nginx/redis ports) and what the Z-stack paper uses as its
F-Stack baseline.

Native-mode notes:

- The stack boots inside iperf3: expect the f-stack banner (and the three
  benign `kernel_sysctlbyname failed` warnings) before "Server listening".
- iperf3 pumps the stack for 100 ms at exit (`atexit`) so queued FINs reach
  the wire — without this the peer only notices closed connections via its
  receive timeout.
- TCP only for now: the UDP connect handshake still does a raw blocking
  read. The port lives in `nix/patches/iperf311-ff-native.patch`
  (development history on the `ff-native` branch in `iperf_fstack/`).

### Example: vhost-user/virtio-user pair, no physical NIC — 12.1 Gbit/s on one host

Two native-iperf F-Stack instances can talk to each other over a DPDK
vhost-user link (one unix socket, shared-memory rings) — no NIC, no vfio
binding, runs on any machine with hugepages. Same topology as a
`--vdev eth_vhost0` test app paired with a virtio_user pktgen.

F-Stack's config already parses `[vdevN]` sections but only ever emitted
`virtio_user` (the frontend); `nix/patches/ff-vdev-eth-vhost.patch` makes
`iface=` emit an `eth_vhost` vdev (the backend, which creates the socket
and serves the rings) and adds `--single-file-segments` (virtio_user must
hand its memory to the backend as a small fd table). The two roles:

| Side | config | vdev | role |
|------|--------|------|------|
| A (server) | `config-vhost-a.ini` | `[vdev0] iface=/tmp/fstack-vhost0.sock` | `eth_vhost0` backend — creates the socket, **start first** |
| B (client) | `config-vhost-b.ini` | `[vdev0] path=/tmp/fstack-vhost0.sock` | `virtio_user0` frontend — connects to it |

Both configs set `nb_vdev=1` (implies `--no-pci`), a distinct
`file_prefix` (two DPDK primaries on one host), distinct cores
(`lcore_mask=2` / `4`), and a private subnet (192.168.31.1 / .2).

```sh
# server, side A (creates /tmp/fstack-vhost0.sock):
sudo FF_CONF=$PWD/config-vhost-a.ini ./result-native/bin/iperf3 -s -B 192.168.31.1

# client, side B (after the socket exists):
sudo FF_CONF=$PWD/config-vhost-b.ini ./result-native/bin/iperf3 -c 192.168.31.1 -t 10 -l 1M
```

Result (2026-06-12, one host, single stream, one core per instance,
1500 MTU, software checksums — the vhost PMD prints "csum will be done in
SW"):

```
[129]   0.00-10.00  sec  14.1 GBytes  12.1 Gbits/sec   sender
[129]   0.00-10.05  sec  14.1 GBytes  12.0 Gbits/sec   receiver
```

Notes:

- Start order matters: the `virtio_user` frontend needs the backend's
  socket at EAL init. Stale sockets from a crashed backend must be removed
  (`rm /tmp/fstack-vhost0.sock`) before restarting.
- The link reports "10000 Mbps" (backend) / "4294967295 Mbps" (frontend);
  both are cosmetic — throughput is bounded by CPU and the shared-memory
  copies, not a link rate.
- Debugging this rig flushed out a latent bug in the native port:
  `is_closed()` in `iperf_util.c` was the one socket-touching call site
  not routed through the `ffn_*` layer, so it probed F-Stack fds with the
  *Linux* `select()` (EBADF) and the server silently dropped every
  accepted data stream. On vfio/physical-NIC setups DPDK keeps enough real
  Linux fds open that the fd number aliases an open file and the probe
  accidentally "works" — worth remembering when a native port misbehaves
  only in some environments.

#### Offload / zero-copy stack — 12.6 → ~29.7 Gbit/s, all config-driven

The 12.1 Gbit/s above is the unoptimized rig. Four offloads, each a single
flag in the f-stack config (no env vars, no rebuild to toggle), take it to
~29.7 Gbit/s on the same one-core-per-instance, single-stream, 1500-MTU
setup:

| `[dpdk]` flag    | effect | alone |
|------------------|--------|-------|
| `rx_csum_trust=1`| trust RX csums on the vhost vdev — neither side computes a full checksum (eth_vhost stops SW-completing, FreeBSD stops re-verifying) | 12.6 → ~20 |
| `tso=1`          | virtio GSO: ~64KB super-segments through the ring (one stack trip per ~34KB, not per 1448B); needs `tso=1` on **both** configs | +~5% |
| `zc_recv=1`      | native iperf drains streams via `ff_recv_mbuf` (no `uiomove`) | — |
| `zc_send=1`      | native iperf sends via `ff_zc_mbuf_ext` + `ff_zc_send` (external-buffer mbuf, no copy) | — |

Measured combinations (all on one host, steady state):

```
all off                       12.6 Gbit/s   (double-csum, copy, 1448B segs)
rx_csum_trust only          ~20.0
+ zc_recv + zc_send         ~22.7
+ tso (everything on)       ~29.7
```

zc and GSO are **super-additive**: GSO removes per-packet overhead, zc
removes per-byte socket copies, so together only the vhost ring copy
remains. All four default to 0 when the key is absent, so other configs
(e.g. the E810 `config.ini`) are unaffected; `rx_csum_trust` is
vhost-only by design (a real NIC that validates all three csums trusts
unconditionally — do **not** set it on a real wire). The committed
`config-vhost-{a,b}.ini` ship with all four on.

Tuning journey for the LD_PRELOAD number (each step measured): 12.9 (baseline after
the timer fixes) -> 13.0 (tso=1 + tx_csum_offoad_skip=0 on the sender; the
two MUST be flipped together on E810 -- csum offload alone or tso alone
trips the NIC's MDD and kills the TX queue) -> 13.9 (FF_IPFW/FF_NETGRAPH
removed from the build) -> 19.2 Gbit/s ([pcap] enable=0; the per-packet
gettimeofday+fwrite in the dump path also BLOCKS the instance loop on file
I/O -- never benchmark with pcap enabled).

Two-host gotchas (all learned the hard way):

- **Both hosts need this patched build** (`nix copy --to ssh://hostB
  $(readlink result)`): a stock f-stack dev build on either end stalls all
  connections after ~1s (the TCP-timer bugs fixed in `nix/patches/`).
- **Intel E810 (ice PMD) requires `tx_csum_offoad_skip=1`**: F-Stack's TX
  checksum-offload descriptors trip the NIC's Malicious Driver Detection
  ("MDD event ... by TDPU" in the instance log) which silently kills the TX
  queue — everything times out. Broadcom bnxt tolerates the same
  descriptors. The proper fix would be correct l2/l3 lengths in F-Stack's
  mbuf TX path.
- **Make sure the second host really uses the second config**: `fstack`
  without `--conf` silently loads `./config.ini` from the cwd. If both ends
  claim the same IP, the only wire traffic is ARP conflict announcements
  ("arp: <mac> is using my IP address") and connects time out.
- The single-stream ceiling here is CPU-bound (one stack core, software
  checksums, no TSO, 1500 MTU). Levers, in payoff order: `tso=1` (test for
  MDD again), jumbo MTU on both ends, multi-queue/multi-instance with
  parallel streams.

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
