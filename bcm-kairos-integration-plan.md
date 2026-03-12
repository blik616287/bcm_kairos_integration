# BCM + Kairos Integration — Architecture Planning Document

## Problem Statement

The current integration rsyncs the Kairos squashfs to a single root partition via BCM's native provisioning. This works — stylus-agent registers with Palette, BCM tracks the node — but it bypasses `kairos-agent install`, resulting in:

- **No COS partitions** (COS_OEM, COS_PERSISTENT, COS_STATE, COS_RECOVERY)
- **No A/B active/passive layout** (no immutability, no atomic upgrades)
- **No recovery partition**
- **Kernel mismatch**: BCM injects its Ubuntu 24.04 6.8.x kernel into the Ubuntu 22.04 Kairos image

Venkat's guidance: "the booted system needs to have kairos partitions and its initramfs to achieve immutability" and "if we can boot a kairos image even without stylus via auroraboot then adding canvos image or stylus is easy bit."

---

## Options Overview

| | Option A | Option B | Option C | Option D | Option E |
|---|---|---|---|---|---|
| **Method** | BCM rsync (current) | Raw image via `dd` | Kairos ISO installer via PXE | AuroraBoot netboot | Ubuntu shim (MAAS pattern) |
| **COS partitions** | No | Yes | Yes | Yes | Yes |
| **Immutability** | No | Yes | Yes | Yes | Yes |
| **BCM node tracking** | Yes (cmd agent) | Requires work | Requires work | No | Partial (during shim phase) |
| **Kernel control** | BCM kernel | Full control | Full control | Full control | Full control |
| **Userdata injection** | bcm-sync script | Manual/script | config_url | Built-in | cloud-init (proven) |
| **Complexity** | Low (working now) | Medium | Medium | High | Medium-High |
| **Production ready** | No (missing COS) | Yes | Yes | Fragile (UEFI broken) | Yes (proven on MAAS) |
| **Prior art** | This project | — | Venkat suggested | — | Venkat implemented on MAAS |

---

## Option A: BCM Native rsync (Current — Baseline)

### How It Works
1. Build Kairos ISO via CanvOS
2. Extract squashfs from ISO
3. Upload to BCM, unsquash to `/cm/images/kairos-image/`
4. `cm-create-image` registers image, installs BCM packages, replaces kernel
5. BCM rsyncs file tree to single root partition on compute node
6. BCM installs GRUB, reboots
7. `bcm-sync-userdata.sh` seeds userdata, stylus-agent registers with Palette

### What Works
- Full BCM node lifecycle (PXE, provisioning, health monitoring, cmd agent)
- Palette registration via stylus-agent
- Automated end-to-end via `make orchestrate`

### What Doesn't Work
- No COS partition layout — single root partition (xfs)
- No immutability — read-write root
- No A/B upgrades, no recovery
- Kernel mismatch: BCM 24.04 kernel on 22.04 userspace
- BCM's `cm-create-image` overwrites Kairos initramfs with its own

### When to Use
- Development and proof-of-concept only
- Validating Palette registration flow
- Testing BCM provisioning pipeline

---

## Option B: Raw Disk Image via `dd` in BCM Installer Image

### How It Works
1. Build a Kairos container image (Ubuntu 24.04 base, matching BCM kernel)
2. Generate raw disk image via AuroraBoot with full COS partition layout
3. Create a BCM "installer" software image containing a systemd service
4. BCM rsyncs the installer image to the compute node (normal provisioning)
5. On first boot, the installer service downloads the raw image and `dd`s it to disk
6. Node reboots into Kairos with proper COS partitions
7. Set `installmode NOSYNC` or `provisioningmethod` to prevent BCM re-provisioning

### Detailed Steps

**Step 1: Build Kairos image with matching kernel**
```dockerfile
FROM quay.io/kairos/kairos-init:v0.6.2 AS kairos-init
FROM ubuntu:24.04
ARG VERSION=1.0.0

# Install Kairos components, skip default kernel
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
  /kairos-init -s install --version "${VERSION}" --skip-steps installKernel

# Install BCM-matching kernel
RUN apt-get update && apt-get install -y \
  linux-image-6.8.0-87-generic \
  linux-modules-6.8.0-87-generic

# Init phase — finds kernel, generates initramfs via dracut
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
  /kairos-init -s init --version "${VERSION}"
```

**Step 2: Generate raw disk image via AuroraBoot**
```bash
docker run --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $PWD:/aurora --rm \
  quay.io/kairos/auroraboot \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "disk.efi=true" \
  --set "disk.size=81920" \
  --set "container_image=<registry>/kairos-bcm:latest" \
  --cloud-config /aurora/cloud-config.yaml
```

Output: `disk.raw` with GPT partition table containing:
- EFI System Partition
- COS_OEM (cloud-config, userdata)
- COS_RECOVERY (recovery image)
- COS_STATE (active + passive system images)
- COS_PERSISTENT (persistent user data)

**Step 3: Create BCM installer image**
```bash
cmsh -c "softwareimage; clone default-image kairos-installer; commit"

# Chroot and add installer script + service
cm-chroot-sw-image /cm/images/kairos-installer
```

Installer script (`/usr/local/sbin/install-kairos.sh`):
```bash
#!/bin/bash
set -e
DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
HEAD_IP="10.141.255.254"

echo "Downloading Kairos raw image..."
curl -o /tmp/kairos.raw http://${HEAD_IP}:8080/kairos/disk.raw

echo "Writing to ${DISK}..."
dd if=/tmp/kairos.raw of=${DISK} bs=16M status=progress conv=fsync
sync

echo "Done. Rebooting into Kairos..."
reboot
```

Systemd service (`/etc/systemd/system/kairos-install.service`):
```ini
[Unit]
Description=Install Kairos Raw Image
After=network-online.target cmd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/install-kairos.sh

[Install]
WantedBy=multi-user.target
```

**Step 4: Deploy**
```bash
# Serve raw image from head node
cp disk.raw /cm/shared/kairos/
cd /cm/shared && python3 -m http.server 8080 &

# Assign installer image to node
cmsh -c "device; use node001; set softwareimage kairos-installer; set installmode FULL; commit"
```

**Step 5: After Kairos boots, prevent re-provisioning**
```bash
cmsh -c "device; use node001; set installmode NOSYNC; commit"
# Or: set installmode SKIP
```

### Pros
- Full COS partition layout with immutability
- Kernel version aligned (Ubuntu 24.04 throughout)
- BCM handles initial PXE boot and network config
- Works for both VMs and physical nodes
- One-shot install — subsequent boots are from disk

### Cons
- Two-phase boot: first into BCM installer, then reboot into Kairos
- Large raw image transfer over internal network (~5-10 GB)
- BCM loses node tracking after `dd` (no cmd agent on Kairos)
- Need to serve raw image via HTTP from head node
- Need to manage `installmode` transition

### BCM Node Tracking
After `dd`, the node boots Kairos — not the BCM-managed image. BCM will see the node as DOWN or UNKNOWN unless:
- The cmd agent is included in the Kairos image (complex, may conflict)
- BCM is configured to accept the node as externally managed
- Node is set to CLOSED state in cmsh

### Estimated Effort
- Build pipeline changes: 2-3 days (Dockerfile, AuroraBoot integration, installer image)
- Testing: 1-2 days
- BCM lifecycle management: 1 day

---

## Option C: Kairos ISO Installer via BCM PXE

### How It Works
1. Build Kairos ISO (via CanvOS or stock Kairos)
2. Extract kernel + initrd from ISO (or download from Kairos releases if not in ISO)
3. Place on BCM head node, serve via TFTP/HTTP
4. Create custom PXE label in BCM pointing to Kairos kernel/initrd
5. Assign PXE label to target node via `set pxelabel`
6. Node PXE boots → Kairos installer runs → creates COS partitions → installs to disk
7. Node reboots into fully installed Kairos with proper partition layout
8. Disable further BCM provisioning for the node

### Detailed Steps

**Step 1: Extract or download boot artifacts**
```bash
# From ISO:
mount -o loop kairos.iso /mnt
cp /mnt/boot/vmlinuz /cm/shared/kairos/
cp /mnt/boot/initrd /cm/shared/kairos/
cp /mnt/rootfs.squashfs /cm/shared/kairos/  # if present
umount /mnt

# Or download release artifacts from Kairos:
# https://github.com/kairos-io/kairos/releases
# kernel, initrd, squashfs are published separately
```

**Step 2: Create cloud-config for automated install**
```yaml
#cloud-config
install:
  auto: true
  device: "auto"
  reboot: true
  partitions:
    persistent:
      size: 0  # fill remaining disk

users:
  - name: kairos
    passwd: kairos
    ssh_authorized_keys:
      - <head_node_pubkey>

stylus:
  site:
    edgeHostToken: "<PALETTE_TOKEN>"
    paletteEndpoint: "api.spectrocloud.com"
    projectUid: "<PROJECT_UID>"
    name: "{{ NODENAME }}"
```

**Step 3: Serve files via HTTP**
```bash
# BCM already runs HTTP on internal network
# Place files where BCM's HTTP server can reach them
# Or use a simple HTTP server:
cd /cm/shared/kairos && python3 -m http.server 8080 &
```

**Step 4: Create PXE boot entry (BIOS — pxelinux)**

Add to `/tftpboot/pxelinux.cfg/template`:
```
LABEL kairos-install
  KERNEL http://10.141.255.254:8080/kairos/vmlinuz
  INITRD http://10.141.255.254:8080/kairos/initrd
  APPEND ip=dhcp rd.neednet=1 netboot install-mode config_url=http://10.141.255.254:8080/kairos/config.yaml live-img-url=http://10.141.255.254:8080/kairos/rootfs.squashfs
```

For UEFI (GRUB2), add to the GRUB config:
```
menuentry 'Kairos Installer' {
    linux http://10.141.255.254:8080/kairos/vmlinuz ip=dhcp rd.neednet=1 netboot install-mode config_url=http://10.141.255.254:8080/kairos/config.yaml live-img-url=http://10.141.255.254:8080/kairos/rootfs.squashfs
    initrd http://10.141.255.254:8080/kairos/initrd
}
```

**Step 5: Assign PXE label to node**
```bash
cmsh -c "device; use node001; set pxelabel kairos-install; commit"
# Reboot node to trigger PXE
```

**Step 6: After installation, switch to disk boot**
```bash
# Kairos installer reboots automatically after install
# Change node to boot from disk, not PXE:
cmsh -c "device; use node001; clear pxelabel; set installmode SKIP; commit"
```

### Pros
- Cleanest approach — Kairos handles its own partitioning natively
- Full COS partition layout (active/passive, OEM, persistent, state, recovery)
- Full immutability and A/B upgrade support
- Kairos initramfs is used (not BCM's)
- Kernel matches the Kairos build (no mismatch)
- Venkat recommended this for production
- BCM still handles DHCP and initial PXE — no competing servers

### Cons
- BCM loses node tracking after Kairos installs (no cmd agent)
- Need to manage PXE label lifecycle (set before install, clear after)
- Need to determine if kernel + initrd are in the ISO or need separate download
- Userdata/nodename injection is trickier (can't modify at BCM provision time)
- Node shows as DOWN in BCM after Kairos boots

### Userdata / Nodename Challenge
In the current approach, `bcm-sync-userdata.sh` injects the BCM-assigned nodename at boot time. With Option C, the cloud-config is baked at PXE time. Solutions:
- Template the cloud-config per-node (generate config-node001.yaml, config-node002.yaml)
- Use Kairos `config_url` with a dynamic endpoint that returns node-specific config based on MAC/IP
- Use Kairos cloud-config templating (`{{ .MachineID }}` or similar)

### Estimated Effort
- PXE configuration: 1 day
- Cloud-config templating: 1-2 days
- Automation scripts: 2-3 days
- Testing: 1-2 days

---

## Option D: AuroraBoot as Netboot Server

### How It Works
1. Run AuroraBoot as a PXE/netboot server on the BCM internal network
2. AuroraBoot uses ProxyDHCP — works alongside BCM's DHCP (no IP conflicts)
3. Compute nodes PXE boot → AuroraBoot responds with Kairos boot artifacts
4. Kairos boots live, runs installer, creates COS partitions, reboots from disk

### How AuroraBoot Netboot Works
```bash
docker run --privileged --net=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $PWD:/aurora --rm \
  quay.io/kairos/auroraboot \
  --set "container_image=<registry>/kairos:latest" \
  --cloud-config /aurora/config.yaml
```

AuroraBoot runs four services:
- **ProxyDHCP** (port 67) — supplements BCM's DHCP with PXE boot info
- **TFTP** (port 69) — serves iPXE bootloader only
- **HTTP** (port 8090) — serves kernel, initrd, squashfs, cloud-config
- **iPXE scripting** — chainloads from TFTP to HTTP for bulk transfer

### Pros
- Native Kairos netboot — designed for this exact use case
- Full COS partition layout
- Cloud-config injection built-in
- Can trigger both live boot (ephemeral) and disk install
- No BCM PXE template modifications needed

### Cons — Significant
- **UEFI is broken**: Known issue (#2529) — AuroraBoot crashes in EFI mode. BIOS-only.
- **Port 67 conflict with BCM**: Both BCM's DHCP and AuroraBoot's ProxyDHCP listen on UDP 67. Unpredictable behavior — whichever responds first wins.
- **Underlying library unmaintained**: `danderson/netboot` (Pixiecore) is no longer maintained upstream
- **BCM loses all node control**: No cmd agent, no health monitoring, nodes show as DOWN
- **Cannot selectively target nodes**: ProxyDHCP responds to ALL PXE requests — BCM nodes that should boot normally will also see AuroraBoot's response
- **Same L2 segment required**: No relay/routing support

### Mitigation Strategies
- Run AuroraBoot on a separate VLAN, move target nodes to that VLAN
- Run AuroraBoot only during install, shut it down after
- Use BCM's PXE instead (Option C) and skip AuroraBoot's netboot entirely

### Verdict
**Not recommended** for integration with BCM. The port 67 conflict and UEFI issues make this fragile. AuroraBoot's value is in **raw disk image generation** (used by Option B), not as a PXE server alongside BCM.

---

## Option E: Ubuntu Shim Partition (MAAS Pattern — Adapted for BCM)

### Background: How Venkat Solved This for MAAS

Venkat implemented Kairos on MAAS and hit the same fundamental problem: MAAS (like BCM) expects to find a standard Linux filesystem with cloud-init, kernel, etc. Kairos's squashfs-based layout confuses it. His solution was a **Ubuntu shim partition** — a brilliant workaround that lets the provisioning system do its thing on a familiar Ubuntu partition, then pivots to Kairos on first boot.

### Key Insight: AuroraBoot Raw Image Partition Layout

AuroraBoot's raw EFI image does NOT start with all 5 COS partitions. It creates only 3:

```
Partition 1: COS_GRUB    (EFI — contains grub.cfg that points to recovery)
Partition 2: COS_OEM     (cloud-config, userdata, grubenv)
Partition 3: COS_RECOVERY (squashfs — the actual Kairos system image)
```

On **first boot**, Kairos boots into the recovery partition and automatically creates:
- COS_STATE (active + passive system images)
- COS_PERSISTENT (persistent user data)

Then reboots into the target (active) partition. This is important — we don't need to pre-create all partitions.

### How It Works for BCM

Adapt Venkat's MAAS approach: insert a bootable Ubuntu partition into the AuroraBoot raw image that BCM can provision normally.

**Step 1: Generate base Kairos raw image via AuroraBoot**
```bash
docker run --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $PWD:/aurora --rm \
  quay.io/kairos/auroraboot \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "disk.efi=true" \
  --set "container_image=<registry>/kairos-bcm:latest" \
  --set "state_dir=/aurora"
```

**Step 2: Insert Ubuntu shim partition**

Create a new raw image with an additional bootable Ubuntu partition:

```
Partition 1: COS_GRUB       (EFI)
Partition 2: COS_OEM        (cloud-config, grubenv, grubcustom)
Partition 3: COS_RECOVERY   (Kairos squashfs)
Partition 4: UBUNTU_ROOTFS  (minimal Ubuntu 24.04 with cloud-init) ← NEW
```

Add a GRUB entry in COS_OEM (`grubcustom`):
```
menuentry 'BCM Kairos Setup' --id 'ubuntu-firstboot' {
    search --no-floppy --label --set=root UBUNTU_ROOTFS
    set img=/boot/vmlinuz
    set initrd=/boot/initrd.img
    linux ($root)$img root=LABEL=UBUNTU_ROOTFS rw console=tty0 console=ttyS0,115200n8
    initrd ($root)$initrd
}
```

Set `grubenv` to boot this entry first: `next_entry=ubuntu-firstboot`

**Step 3: Add first-boot script to Ubuntu shim**

Place in `/var/lib/cloud/scripts/per-instance/setup-kairos.sh` on the Ubuntu partition:
```bash
#!/bin/bash
set -euo pipefail

# Mount COS_OEM
OEM_PARTITION=$(blkid -L COS_OEM)
mkdir -p /mnt/oem_temp
mount -o rw "$OEM_PARTITION" /mnt/oem_temp

# Copy userdata from BCM/cloud-init to COS_OEM
# BCM provides userdata via its own mechanism — adapt as needed
if [ -f "/var/lib/cloud/instance/user-data.txt" ]; then
    cp /var/lib/cloud/instance/user-data.txt /mnt/oem_temp/userdata.yaml
    echo "Userdata copied to COS_OEM"
fi

# For BCM: generate userdata from node context
# The Ubuntu partition has BCM's cmd agent, so we know the nodename
NODENAME=$(hostname)
cat > /mnt/oem_temp/99_userdata.yaml << USERDATA
#cloud-config
install:
  auto: true
  device: "auto"
  reboot: true
stylus:
  site:
    edgeHostToken: "${PALETTE_TOKEN}"
    paletteEndpoint: "api.spectrocloud.com"
    projectUid: "${PROJECT_UID}"
    name: "${NODENAME}"
USERDATA

# Switch GRUB to boot recovery partition next
grub-editenv /mnt/oem_temp/grubenv set next_entry=recovery

umount /mnt/oem_temp
rmdir /mnt/oem_temp

echo "BCM Kairos setup complete. Rebooting into Kairos recovery..."
reboot
```

**Step 4: Deploy via BCM**

The Ubuntu shim partition is a standard Linux filesystem. BCM can:
- Detect it via `cm-create-image` (finds kernel, cloud-init, etc.)
- rsync its packages to it (BCM treats it as the "software image")
- Install GRUB (but we need to prevent it from overwriting COS_GRUB — see MAAS lesson below)

**Step 5: Boot sequence**

```
1. BCM PXE boots node → node-installer rsyncs Ubuntu shim
2. BCM installs GRUB → node reboots
3. GRUB boots "ubuntu-firstboot" (the Ubuntu shim)
4. Cloud-init / first-boot script runs:
   - Copies userdata to COS_OEM
   - Sets grubenv next_entry=recovery
   - Reboots
5. GRUB boots COS_RECOVERY
6. Kairos recovery creates COS_STATE + COS_PERSISTENT
7. Kairos reboots into active partition
8. stylus-agent registers with Palette
```

### Critical Lesson from MAAS: Protect the EFI Partition

Venkat hit this exact problem: MAAS's curtin detected the EFI partition and the kernel in the Ubuntu partition, then **overwrote the original EFI/GRUB** — breaking the Kairos boot chain.

BCM will likely do the same thing. `cm-create-image` and the node-installer will try to:
- Replace the kernel with BCM's kernel
- Regenerate the initramfs
- Overwrite GRUB configuration

**MAAS solution**: No-op curtin hooks file (`/curtin/curtin-hooks`) that skips built-in hooks, plus a custom `finalize` script that only handles cloud-config setup.

**BCM equivalent**: We need to prevent BCM from touching the COS_GRUB (EFI) partition. Possible approaches:
- Use `installmode SKIP` after the initial `dd` of the raw image (BCM doesn't touch disk)
- Use finalize scripts in the node-installer to restore COS_GRUB after BCM modifies it
- Don't use `cm-create-image` on the raw image — `dd` it directly (Option B approach) then use the Ubuntu shim for BCM compatibility

### Hybrid Approach: `dd` + Ubuntu Shim

The cleanest version combines Option B (dd raw image) with the MAAS shim pattern:

1. BCM provisions a minimal "installer" software image (standard Ubuntu, BCM-compatible)
2. Installer image has a systemd service that `dd`s the Kairos raw image (with Ubuntu shim) to disk
3. Node reboots → boots Ubuntu shim → copies userdata → boots Kairos recovery
4. Kairos creates remaining partitions, reboots into active
5. Set `installmode NOSYNC` in BCM to prevent re-provisioning

This avoids the EFI overwrite problem entirely because BCM never sees the COS partitions — it only provisions the installer image, and the `dd` happens on the node itself.

### Pros
- Full COS partition layout (created natively by Kairos recovery)
- BCM compatibility via Ubuntu shim (familiar filesystem for provisioning systems)
- Userdata injection via standard cloud-init mechanisms
- Pattern proven in production (Venkat's MAAS implementation)
- Nodename injection works naturally (Ubuntu shim has BCM hostname)

### Cons
- Three-phase boot: BCM installer → Ubuntu shim → Kairos recovery → Kairos active
- Complex image construction (AuroraBoot raw + Ubuntu shim insertion)
- BCM loses node tracking after Kairos takes over (no cmd agent)
- Need to manage the transition from BCM-managed to Kairos-managed
- Raw image size is large (~5-10 GB transfer)

### Estimated Effort
- AuroraBoot image generation pipeline: 2-3 days
- Ubuntu shim partition construction + scripts: 2-3 days
- BCM installer image + `dd` service: 1-2 days
- First-boot userdata injection script: 1 day
- Testing full boot chain: 2-3 days
- Total: ~10-14 days

---

## Kernel Mismatch Solution (Applies to All Options)

### The Problem
- BCM 11.0 runs Ubuntu 24.04 with kernel 6.8.0-87-generic
- Default Kairos/CanvOS builds use Ubuntu 22.04 with its own kernel
- In Option A, BCM's `cm-create-image` replaces the kernel, creating a 24.04 kernel on 22.04 userspace
- Risk: kernel module mismatches, driver incompatibilities

### The Solution: Build Kairos on Ubuntu 24.04 with BCM's Kernel

Using Kairos Factory (`kairos-init`):

```dockerfile
FROM quay.io/kairos/kairos-init:v0.6.2 AS kairos-init
FROM ubuntu:24.04
ARG VERSION=1.0.0

# Phase 1: Install Kairos components, skip default kernel
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
  /kairos-init -s install --version "${VERSION}" --skip-steps installKernel

# Install the exact kernel BCM uses
RUN apt-get update && apt-get install -y \
  linux-image-6.8.0-87-generic \
  linux-modules-6.8.0-87-generic \
  linux-modules-extra-6.8.0-87-generic

# Phase 2: Init — finds installed kernel, symlinks, generates initramfs
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
  /kairos-init -s init --version "${VERSION}"
```

This gives:
- Ubuntu 24.04 userspace (matches BCM)
- Kernel 6.8.0-87-generic (matches BCM exactly)
- Kairos initramfs generated by dracut for that kernel
- Full Kairos agent, immucore, stylus-agent included

Applies to Options B, C, and D. Option A would still have BCM override the kernel via `cm-create-image`, but the base OS match reduces risk.

---

## Recommendation

### Phase 1 (Now): Continue with Option A — Done
The current integration is a working proof-of-concept:
- Palette registration flow validated
- BCM provisioning pipeline tested end-to-end
- Full automation via `make orchestrate`
- Confirms: stylus-agent, bcm-sync-userdata, cmd agent all work together

### Phase 2 (Next): Implement Option C or E

Two strong candidates for the production path:

**Option C (Kairos ISO Installer via BCM PXE)** — Venkat's recommended approach:
- Cleanest architectural boundary: BCM owns network boot, Kairos owns disk
- Kairos handles its own partitioning natively
- Uses BCM's existing PXE infrastructure (`pxelabel` mechanism)
- Simpler image pipeline (no raw image construction)
- Risk: untested — need to verify BCM `pxelabel` can serve custom kernel/initrd

**Option E (Ubuntu Shim — MAAS Pattern)** — Venkat's proven approach:
- Already implemented and working on MAAS
- Pattern translates directly to BCM (both are provisioning systems that expect standard Linux)
- Userdata injection via cloud-init is well-understood
- More complex boot chain but proven in production
- Risk: BCM's EFI handling may differ from MAAS's curtin

**Recommendation**: Start with Option C (simpler). If BCM's PXE customization proves too limited or BCM breaks the Kairos boot chain, fall back to Option E which has proven workarounds for exactly these problems.

Key work items (shared across C and E):
1. Build Kairos image on Ubuntu 24.04 with BCM-matching kernel (`kairos-init --skip-steps installKernel`)
2. Verify AuroraBoot raw image generation works with CanvOS image
3. Test BCM `pxelabel` with custom kernel/initrd (Option C gate)
4. If C fails: implement Ubuntu shim partition construction (Option E)
5. Build per-node userdata templating (nodename injection)
6. Determine BCM node tracking strategy post-install

### Phase 3 (Future): Kairos Upstream Improvements
Per Venkat's notes, two upstream changes would simplify everything:
1. **AuroraBoot integration**: If Kairos team accepts the shim pattern, it could be built into AuroraBoot directly
2. **yip MAAS/BMC datasource provider**: If yip supported fetching userdata from provisioning systems directly (MAAS metadata server, or a BCM equivalent), the Ubuntu shim partition becomes unnecessary

### Not Recommended: Option D (AuroraBoot as PXE Server)
Port 67 conflicts with BCM's DHCP, UEFI support is broken, and it adds unnecessary infrastructure complexity. Use AuroraBoot for image generation only.

---

## Open Questions

1. **Does the CanvOS-built ISO contain kernel + initrd in `/boot/`?** If not, where to source them for Option C?
2. **Can BCM's `pxelabel` mechanism serve HTTP-hosted kernels?** Or only TFTP paths under `/tftpboot/`? This is the gate for Option C.
3. **Does BCM's node-installer overwrite the EFI partition?** MAAS's curtin did this and broke the Kairos boot chain. If BCM does the same, Option C needs a workaround (or we fall back to Option E).
4. **What is the BCM node tracking strategy?** After Kairos installs its own OS, BCM's cmd agent won't be present. Options: include cmd in Kairos image, use CLOSED state, or accept nodes as unmanaged.
5. **Per-node cloud-config**: How to template the nodename dynamically? Options: `config_url` pointing to a per-node endpoint, cloud-init on the Ubuntu shim (Option E), or BCM finalize scripts.
6. **Secure Boot**: Does the target hardware require Secure Boot? AuroraBoot's UEFI support is broken, and custom PXE entries may need signed bootloaders.
7. **BCM cmd agent on Kairos**: Is it feasible to install BCM's cmd agent into the Kairos image so BCM can still monitor the node post-install? What are the conflicts with Kairos immutability?
8. **AuroraBoot + CanvOS compatibility**: Can AuroraBoot consume a CanvOS-built container image directly for raw image generation? Venkat's MAAS implementation used `container_image=us-east1-docker.pkg.dev/.../canvos/palette-installer-image:v4.7.4` — confirming this works.
9. **BCM equivalent of MAAS curtin hooks**: BCM's node-installer has `initialize` and `finalize` scripts (steps 5 and 11 of provisioning). Can these be used to protect or restore the COS_GRUB/EFI partition after BCM modifies it?
10. **yip datasource for BCM**: Could a custom yip datasource provider be written to fetch userdata from BCM's metadata/cmd daemon directly, eliminating the need for the Ubuntu shim partition entirely?

---

## Appendix: MAAS Implementation Reference (Venkat Srinivasan)

### Summary
Venkat implemented Kairos on MAAS by inserting a bootable Ubuntu partition into the AuroraBoot raw image. MAAS deploys the image, boots the Ubuntu shim, which copies userdata to COS_OEM and pivots to Kairos recovery. Key challenges and solutions:

### Problem 1: MAAS Can't Find Standard Linux Filesystem
MAAS expects cloud-init, kernel, etc. in a standard partition. Kairos uses squashfs.
**Solution**: Add an Ubuntu partition (from `noble-server-cloudimg-amd64.tar.gz`) to the raw image with label `UBUNTU_ROOTFS`.

### Problem 2: MAAS Overwrites EFI Partition
MAAS's curtin detected the kernel in the Ubuntu partition and tried to update GRUB, overwriting the COS_GRUB EFI partition.
**Solution**: No-op `curtin-hooks` file that skips built-in hooks:
```bash
#!/bin/bash
echo "Skipping builtin curtin hooks"
exit 0
```

### Problem 3: Cloud-Init Config Not Applied
The no-op curtin hooks also skipped the MAAS cloud-init datasource configuration.
**Solution**: Custom Python `curtin-hooks` that only runs `handle_cloudconfig()` from curtin's library, setting up the MAAS datasource without touching GRUB/kernel.

### Problem 4: Userdata Format Mismatch
MAAS cloud-init doesn't understand Kairos yip format.
**Solution**: `per-instance` cloud-init script that copies raw userdata to COS_OEM, sets `grubenv next_entry=recovery`, and reboots.

### Boot Sequence (MAAS)
```
MAAS deploys raw image → boots Ubuntu shim → cloud-init runs →
copies userdata to COS_OEM → sets grubenv → reboots →
Kairos recovery boots → creates COS_STATE + COS_PERSISTENT →
reboots into active → stylus-agent registers
```

### Scripts
- Image construction: https://drive.google.com/file/d/1NZJqQqA3zPndr8qqJ-DFZHa5EN4JHa6z
- Setup/deployment: https://drive.google.com/file/d/1Xjibuq9e-sPHTSSSB0j3oZ_Xcua38zGq
