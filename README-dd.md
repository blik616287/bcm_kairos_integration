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

# BCM head node (if not already running)
make download-iso
make bcm-prepare
make bcm-run

# Option B pipeline
make kairos-build        # Build CanvOS ISO with BCM integration (~30-60 min)
make kairos-raw          # Generate pre-installed raw disk via QEMU (~5 min)
make kairos-deploy-dd    # Upload to BCM, configure installer image
make kairos-run-dd       # Launch compute node (PXE → dd → active boot)
```

## Pipeline DAG

```
download-iso → bcm-prepare → bcm-run ──────┐
                                            ├── kairos-deploy-dd → kairos-run-dd
kairos-build → kairos-raw ─────────────────┘
```

The BCM branch and Kairos build branch run in parallel. They converge at the deploy step, which requires both the BCM head node and the raw disk image.

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
  6. Via serial: copy cloud-config to /oem/, run kairos-agent install, poweroff
  7. Trim sparse zeros (fallocate --dig-holes): 80GB → ~9GB on disk
  8. Generate SHA256 checksum
```

The resulting raw image contains all 5 COS partitions with the active image already deployed:

| Partition | Label | Size | Contents |
|-----------|-------|------|----------|
| 1 | COS_GRUB | 64M | EFI bootloader (GRUB) |
| 2 | COS_OEM | 5G | Cloud-config (`90_custom.yaml`) |
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
  6. Configure compute node in cmsh (MAC, installmode=FULL, image=kairos-installer)
  7. Generate ramdisks for the installer image
```

**Output:** BCM head node configured to PXE boot compute nodes with the dd installer.

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
    5. Create "kairos" BCM category with irrelevant health checks disabled
    6. NFS mount BCM default-image rootfs
    7. Fetch node-specific SSL certificates from BCM
    8. Start BCM cmd daemon in isolated mount namespace (unshare + chroot)

Phase 4: Palette Registration
  - bcm-sync-userdata.sh seeds /run/stylus/userdata
  - Injects stylus.registration into /proc/cmdline via bind mount
  - stylus-agent registers with Palette
```

**Output:** Running Kairos compute node with BCM cmd reporting UP and stylus-agent active.

## Cloud-Config Boot Stages

The cloud-config (`90_custom.yaml`) baked into COS_OEM contains all BCM integration logic. Everything runs autonomously at boot — no external scripts or manual intervention.

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

3. **Health Check Category**: Creates a `kairos` BCM category with `interfaces`, `mounts`, and `ntp` health checks disabled (these check for BCM-managed services that don't exist on Kairos nodes). Assigns the node to this category.

4. **BCM cmd Daemon**: Runs the BCM cmd daemon in an isolated mount namespace to report node health to the BCM head node:
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
- **Userdata seeding**: Copies `/oem/99_userdata.yaml` to `/run/stylus/userdata` so stylus-agent finds its config.
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

## Validation Checklist

After deployment, these should all pass:

| Check | Expected |
|-------|----------|
| `/usr/bin/bcm-compat-fixes.sh` | Present (immutable root) |
| `/usr/bin/bcm-sync-userdata.sh` | Present (immutable root) |
| `systemctl status bcm-compat-fixes` | `active (exited)`, status=0 |
| `systemctl status stylus-agent` | `active (running)`, ExecStartPre status=0 |
| `ps aux \| grep "cmd -s"` | BCM cmd daemon running via unshare |
| `systemctl list-units --failed` | 0 failed units |
| `mount \| grep "tmpfs on /run " \| wc -l` | 1 (no mount leaks) |
| `cat /run/cos/active_mode` | 1 (active, not recovery) |
| `blkid \| grep COS` | All 5 partitions (GRUB, OEM, RECOVERY, STATE, PERSISTENT) |
| BCM `device list` | Node shows `[   UP   ]` |
| BCM `latesthealthdata` | ManagedServicesOk, diskspace, dmesg, ldap, lustre, oomkiller, ssh2node = PASS |

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

## Known Issues

- **COS_PERSISTENT masks `/usr/local`**: Kairos bind-mounts COS_PERSISTENT over `/usr/local` for writable local storage. Any files baked into the image at `/usr/local/bin/` are hidden. Custom scripts must go in `/usr/bin/` instead.
- **Node name from BCM**: The node name is whatever BCM has for the device's MAC address. If BCM renames the device (e.g., when cmd connects with a different hostname), subsequent deployments will use the new name. The boot stage queries by MAC, not by a hardcoded name.
- **Palette registration timeout**: The deploy script waits 300s for Palette registration. If stylus-agent can't reach the Palette API (network, token, or rate-limit issues), the deploy completes with a warning but the node is otherwise fully functional.
- **Health check stale data**: After switching a node to the `kairos` category (which disables `interfaces`, `mounts`, `ntp` checks), old FAIL results persist until they age out (~2 health check cycles). This is cosmetic.
- **Disk image size**: The raw image is 80GB (sparse, ~9GB on disk). The gzipped upload is ~4.6GB. COS_PERSISTENT auto-grows to fill the target disk at boot.
