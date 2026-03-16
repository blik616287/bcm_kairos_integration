# Option B: Raw Disk Image Deployment (dd)

Deploys Kairos edge compute nodes using a fully pre-installed raw disk image. Instead of BCM rsyncing a squashfs to disk (Option A), this approach:

1. Builds a CanvOS ISO with BCM integration scripts
2. Runs `kairos-agent install` inside a QEMU VM to produce a raw disk with all 5 COS partitions
3. BCM PXE boots the compute node, dd's the raw image to disk, and reboots
4. Kairos boots directly into active mode — no recovery reset, no multi-reboot cycle
5. Boot stages autonomously configure BCM integration (NOSYNC, cmd daemon, health checks, Palette registration)

## Quick Start

```bash
# Prerequisites
git submodule update --init --recursive
cp env.json.example env.json
# Edit env.json: bcm_password, palette_token, palette_project_uid, jfrog_token
# Set deploy_method to "option-b" and container_source to "canvos"
make setup

# Single command — full parallel DAG pipeline
make kairos-stop       # Kill any running Kairos VM (prevents port conflicts)
make orchestrate       # Builds BCM + Kairos in parallel, deploys, validates
```

Or step by step:

```bash
make download-iso        # Download BCM ISO from JFrog
make bcm-prepare         # Patch BCM ISO for auto-install
make bcm-run             # Install + boot BCM head node (~20 min)
make kairos-build        # Build CanvOS ISO with BCM integration (~10 min)
make kairos-raw          # Generate pre-installed raw disk via QEMU (~5 min)
make kairos-deploy-dd    # Upload to BCM, configure installer + kairos category
make kairos-run-dd       # Launch compute node (PXE → dd → active boot)
make kairos-validate     # Run 18-point validation
```

## Pipeline DAG

```
download-iso → bcm-prepare → bcm-run ──────┐
                                            ├── kairos-deploy-dd → kairos-run-dd → validate
kairos-build → kairos-raw ─────────────────┘
```

The BCM branch and Kairos build branch run in parallel. They converge at the deploy step, which requires both the BCM head node and the raw disk image. `make orchestrate` runs this DAG automatically with rolling status display, dirty file detection, and cascading invalidation.

## Validation Results (End-to-End)

### Node Validation — 17/18 PASS, 0 FAIL

| # | Category | Check | Result | Detail |
|---|----------|-------|--------|--------|
| 1 | OS | OS identified | PASS | Ubuntu 22.04.5 LTS |
| 2 | OS | Kairos release | PASS | v3.5.9 |
| 3 | OS | kairos-agent | PASS | v2.24.10 |
| 4 | Boot | Kernel | PASS | 6.8.0-87-generic |
| 5 | Boot | Registration cmdline | PASS | stylus.registration present |
| 6 | Network | Interface | PASS | 10.141.0.1/16 |
| 7 | Services | Kairos/Stylus services | PASS | 5 services (stylus-agent, stylus-operator, remote-shell running) |
| 8 | Services | stylus-agent | PASS | active |
| 9 | Services | BCM cmd daemon | PASS | running (3 processes via unshare) |
| 10 | Config | SSH login | PASS | root key auth via BCM head node |
| 11 | Config | Cloud-config | PASS | present in /oem/ |
| 12 | Config | Palette registration | WARN | pending (stylus-agent registering in background) |
| 13 | Immutability | COS_OEM partition | PASS | /dev/vda2 |
| 14 | Immutability | COS_RECOVERY partition | PASS | /dev/vda3 |
| 15 | Immutability | COS_STATE partition | PASS | /dev/vda4 |
| 16 | Immutability | COS_PERSISTENT partition | PASS | /dev/vda5 |
| 17 | Immutability | Root filesystem | PASS | read-only (immutable) |
| 18 | Immutability | COS layout | PASS | cos-layout.env present |

### BCM Health Checks — 9/9 PASS

| Health Check | Category | Status |
|-------------|----------|--------|
| ManagedServicesOk | Internal | PASS |
| cuda-dcgm | OS | PASS |
| defaultgateway | Network | PASS |
| diskspace | Disk | PASS |
| dmesg | OS | PASS |
| ldap | OS | PASS |
| lustre | Disk | PASS |
| oomkiller | OS | PASS |
| ssh2node | Network | PASS |

## Pipeline Steps

### 1. `make kairos-build` — Build CanvOS ISO

Builds the Kairos edge installer ISO using the CanvOS Earthly build system. `build-canvos.sh` applies the following patches before building:

| Patch | Target | Purpose |
|-------|--------|---------|
| `wget ifupdown nfs-common` | Earthfile `base-image` packages | BCM networking + NFS for cmd daemon |
| dracut nfit skip | Earthfile `base-image` dracut | Prevents build failure on missing `libnvdimm` kernel module |
| BCM scripts | Dockerfile (line 31 customization point) | `bcm-compat-fixes.sh` and `bcm-sync-userdata.sh` in `/usr/bin/` |

Scripts are placed in `/usr/bin/` (not `/usr/local/bin/`) because Kairos mounts COS_PERSISTENT over `/usr/local` at boot, which would hide files baked into the immutable root.

The systemd units in `src/canvos/overlay/files/etc/` are copied into the CanvOS overlay and included via the standard Earthfile `COPY overlay/files/etc/ /etc/` mechanism.

**Output:** `build/palette-edge-installer.iso` (~1.6 GB)

### 2. `make kairos-raw` — Generate Pre-Installed Raw Disk Image

Creates a fully-installed raw disk by booting the CanvOS ISO inside a temporary QEMU VM and running `kairos-agent install` via the serial console.

```
generate-raw-image.sh:
  1. Generate cloud-config with Palette credentials + BCM integration boot stages
  2. Create FAT32 user-data disk (config delivery for QEMU)
  3. Create blank 80GB raw disk
  4. Boot QEMU: CanvOS ISO (CD-ROM) + blank disk (virtio) + user-data disk
  5. Wait 90s for ISO to boot to root shell
  6. Via serial: copy cloud-config to /oem/, run kairos-agent install
  7. After install: mount OEM partition, restore cloud-config as /oem/99_bcm.yaml, poweroff
  8. Trim sparse zeros (fallocate --dig-holes): 80GB → ~9GB on disk
  9. Generate SHA256 checksum
```

The cloud-config is saved to `/oem/` before the install (so `kairos-agent` can read it for stylus validation), then restored as `99_bcm.yaml` after the install (because `kairos-agent install` overwrites `90_custom.yaml` with its own generated config).

The resulting raw image contains all 5 COS partitions with the active image already deployed:

| Partition | Label | Size | Contents |
|-----------|-------|------|----------|
| 1 | COS_GRUB | 64M | EFI bootloader (GRUB) |
| 2 | COS_OEM | 5G | Cloud-config (`90_custom.yaml` + `99_bcm.yaml`) |
| 3 | COS_RECOVERY | ~20G | `cOS/recovery.img` (fallback) |
| 4 | COS_STATE | ~25G | `cOS/active.img` + `cOS/passive.img` |
| 5 | COS_PERSISTENT | ~30G | Writable persistent storage |

This image boots directly into active mode — no recovery-then-reset cycle. One dd, one reboot, active Kairos.

**Output:** `build/kairos-disk.raw` (~9GB sparse, ~4.6GB gzipped)

### 3. `make kairos-deploy-dd` — Deploy to BCM Head Node

Uploads the raw image and configures BCM to provision compute nodes with a dd-based installer.

```
deploy-kairos-dd.sh:
  1. Compress raw image (gzip) and upload to BCM head node
  2. Start HTTP server on BCM to serve the compressed image
  3. Create BCM "kairos-installer" software image with:
     - dd installer script (downloads .gz, decompresses, dd's to /dev/vda)
     - systemd service to run the installer on first boot
     - sysrq-trigger reboot (works even after dd overwrites the boot disk)
  4. Generate SSH key pair for Kairos → BCM authentication
  5. Export BCM default-image and /cm/shared via NFS
  6. Configure "kairos" category:
     - softwareimage = kairos-installer
     - installmode = FULL
     - Disabled health checks: interfaces, mounts, ntp
     - Set as default category for new physical nodes
  7. Configure node001 with compute MAC and kairos category
  8. Generate ramdisk for the installer image (shared by all kairos-category nodes)
```

**Output:** BCM head node configured to PXE boot compute nodes with the dd installer. Any new node added to BCM automatically gets the `kairos` category and deploys via PXE.

### 4. `make kairos-run-dd` — Launch Compute Node

Launches the compute node VM and monitors the full boot sequence:

```
Phase 1: BCM Provisioning (~3 min)
  - PXE boot → BCM rsyncs kairos-installer image to disk → reboot

Phase 2: dd + Kairos Boot (~4 min)
  - Installer boots → downloads raw.gz from BCM → dd to /dev/vda → sysrq reboot
  - Kairos boots directly into active mode (GRUB → COS_STATE → active.img)

Phase 3: BCM Integration (automatic, ~1 min)
  - Cloud-config boot stages execute autonomously:
    1. Query BCM for node name by MAC address
    2. Set hostname + write Palette edge name to /oem/91_palette_name.yaml
    3. Install BCM head node's root SSH key (for ssh2node health check)
    4. Set installmode NOSYNC on BCM (prevents re-provisioning)
    5. NFS mount BCM default-image rootfs
    6. Fetch node-specific SSL certificates from BCM
    7. Start BCM cmd daemon in isolated mount namespace (unshare + chroot)

Phase 4: Palette Registration (background)
  - bcm-sync-userdata.sh seeds /run/stylus/userdata
  - Injects stylus.registration into /proc/cmdline via bind mount
  - stylus-agent registers with Palette
```

**Output:** Running Kairos compute node with BCM cmd reporting UP and stylus-agent active.

## Adding New Nodes

The `kairos` category is set as the default for new physical nodes. To add a new node:

**BCM Web UI:** Devices → Add → Physical Node → set name + MAC → Save

**cmsh:**
```
device
add physicalnode palette-edge-005
set mac aa:bb:cc:dd:ee:ff
commit
```

The node inherits `softwareimage=kairos-installer`, `installmode=FULL`, kernel parameters, and disabled health checks from the `kairos` category. No per-node configuration needed beyond name and MAC. The ramdisk is shared across all nodes in the category. The boot stages in the cloud-config handle everything else autonomously (node name from BCM, NOSYNC, cmd daemon, Palette registration).

## Cloud-Config Architecture

The cloud-config is stored at `/oem/99_bcm.yaml` on the OEM partition. It contains all BCM integration logic. Everything runs autonomously at boot — no external scripts or manual intervention.

### Palette Configuration

```yaml
stylus:
  site:
    paletteEndpoint: api.spectrocloud.com
    edgeHostToken: <token>
    projectUid: <uid>
```

The `stylus.site.name` is NOT set statically. A boot stage queries BCM by MAC address to get the node name and writes it dynamically to `/oem/91_palette_name.yaml`.

### BCM Integration Boot Stage

A single boot stage handles all BCM integration:

1. **Node Identity**: Queries BCM via SSH (`echo -e 'device\nlist' | cmsh | grep <MAC>`) to get the BCM-assigned device name. Falls back to `hostname` if BCM is unreachable.

2. **NOSYNC**: Sets `installmode NOSYNC` on BCM to prevent the head node from rsyncing its default-image over the Kairos immutable root.

3. **BCM cmd Daemon**: Runs the BCM cmd daemon in an isolated mount namespace to report node health to the BCM head node:
   - NFS mounts the BCM default-image rootfs (guaranteed library compatibility)
   - Fetches node-specific SSL certificates from BCM (`/cm/node-installer/certificates/<MAC>/`)
   - Patches `cmd.conf` with the head node IP
   - Runs cmd via `unshare --mount --fork chroot` (prevents symlink mount leaks to the host)

### Why `unshare` Instead of a Container Runtime

The BCM default-image rootfs has `var/run -> /run` (a symlink). A bare `chroot` would follow this symlink and mount tmpfs over the **host's** `/run`, destroying systemd's runtime state. Options considered:

| Approach | Problem |
|----------|---------|
| Bare chroot | Symlink in NFS rootfs leaks mounts to host `/run`, breaking systemd |
| Podman | Conflicts with dracut during CanvOS build; heavy dependency |
| containerd/ctr | k3s's containerd isn't running at boot time; chicken-and-egg |
| `unshare --mount` | Creates isolated mount namespace. Symlinks stay contained. Zero dependencies. |

`unshare --mount --fork` is the same isolation mechanism containers use internally, without needing a container runtime.

## BCM Overlay Scripts

Two scripts in `src/canvos/overlay/files/usr/bin/` are baked into the CanvOS image via the Dockerfile customization point:

### `bcm-compat-fixes.sh`

Runs once at boot (`bcm-compat-fixes.service`, `Type=oneshot`). Fixes compatibility issues from BCM provisioning:

- Sets hostname from `/etc/hostname` (BCM writes it but the hostname isn't applied after PXE pivot-root)
- Fixes the `resolved` network hook (`return` outside function → `exit 0`)
- Replaces dead `resolv.conf` symlink (systemd-resolved is masked by BCM)

### `bcm-sync-userdata.sh`

Runs before stylus-agent starts (`ExecStartPre` in `bcm-sync.conf` drop-in):

- **Registration mode**: BCM PXE boot doesn't pass `stylus.registration` on the kernel cmdline. Detects unregistered nodes and injects it via `/proc/cmdline` bind mount.
- **Userdata seeding**: Copies cloud-config to `/run/stylus/userdata` so stylus-agent finds its config.
- **Hostname sync**: Updates the Palette edge name in userdata to match the BCM-assigned hostname.

## Build Artifacts

```
build/
├── palette-edge-installer.iso    # CanvOS ISO with BCM integration (1.6 GB)
├── palette-edge-installer.iso.sha256
├── kairos-disk.raw               # Pre-installed raw disk, sparse (~9 GB on disk)
├── kairos-disk.raw.gz            # Compressed for upload (~4.6 GB)
├── kairos-disk.raw.sha256
├── bcm-kairos-key                # SSH key pair: Kairos → BCM authentication
├── bcm-kairos-key.pub
├── userdata.img                  # FAT32 config disk for QEMU install (4 MB, temporary)
├── compute-node-disk.qcow2       # Kairos compute node VM disk (created by deploy)
└── bcm-disk.qcow2                # BCM head node VM disk
```

## Configuration

Set these fields in `env.json` for Option B:

```json
{
  "deploy_method": "option-b",
  "container_source": "canvos",
  "bcm_password": "...",
  "palette_token": "...",
  "palette_project_uid": "...",
  "jfrog_token": "..."
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `deploy_method` | No | `option-a` | Set to `option-b` for raw disk deployment |
| `container_source` | No | `canvos` | `canvos` (with stylus-agent) or `kairos-init` (standalone) |

All other fields are shared with Option A (see main README).

## Differences from Option A

| Aspect | Option A (rsync squashfs) | Option B (raw disk dd) |
|--------|--------------------------|------------------------|
| Image format | Squashfs extracted to BCM image dir | Pre-installed raw disk with COS partitions |
| Provisioning | BCM rsyncs image + installs GRUB | BCM rsyncs installer, installer dd's raw image |
| Boot sequence | PXE → rsync → GRUB install → boot | PXE → rsync installer → dd → reboot → active |
| Recovery/reset | Not applicable (BCM manages root) | Built-in COS_RECOVERY partition |
| Immutability | None (BCM can rsync at will) | Full COS immutability (read-only root, overlayfs) |
| NOSYNC required | No (BCM manages the image) | Yes (prevents BCM from overwriting Kairos) |
| BCM cmd daemon | Runs natively (BCM image) | Runs in NFS chroot via `unshare --mount` |
| Palette binaries | In BCM image at `/opt/spectrocloud/` | In COS active.img (from CanvOS ISO install) |
| Multi-node scaling | Per-node image config | Category-based: one image, one ramdisk, N nodes |

## Known Issues

- **COS_PERSISTENT masks `/usr/local`**: Kairos bind-mounts COS_PERSISTENT over `/usr/local` for writable local storage. Any files baked into the image at `/usr/local/bin/` are hidden. Custom scripts must go in `/usr/bin/` instead.
- **kairos-agent overwrites `/oem/90_custom.yaml`**: During QEMU install, `kairos-agent install` replaces `90_custom.yaml` with its own generated config. The BCM cloud-config is saved separately as `99_bcm.yaml` to survive this.
- **Node name from BCM**: The node name is whatever BCM has for the device's MAC address. If BCM renames the device (e.g., when cmd connects with a different hostname), subsequent deployments will use the new name. The boot stage queries by MAC, not by a hardcoded name.
- **Port 4321 conflict**: The Kairos VM uses TCP port 4321 for the serial console. Run `make kairos-stop` before `make clean-all` to ensure the VM is killed — `clean-all` removes PID files but doesn't kill processes.
- **Disk image size**: The raw image is 80GB (sparse, ~9GB on disk). The gzipped upload is ~4.6GB. COS_PERSISTENT auto-grows to fill the target disk at boot.
