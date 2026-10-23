# Qubes OS 4.3 CI on a bare-metal NUC

A dedicated Intel NUC (NUC10FNH) runs Qubes OS 4.3. On every push to
`main`, Gitea Actions:

1. builds the qubes-guix installer ISO at that commit on guix-subs
   (`iso/qubes-guix-iso`, driven over SSH);
2. on the NUC, installs a Guix template from it with `dom0/qubes-guix-create
   --unattended --template --test`, which also runs `qubes-guix-test`;
3. from that template, without another install, makes and tests a
   template, an AppVM and a StandaloneVM, in HVM and in PVH
   (`ci/dom0/test-variants.sh`);
4. optionally runs Qubes' own integration test modules against the template;
5. collects the results.

```
Gitea ──► act_runner (Debian LXC, user ci) ◄── reverse SSH tunnel ───┐
             │ ssh beto@guix-subs: sync, build the ISO, copy it back  │
             │ ssh -p 2222 127.0.0.1                                  │
             └──────────────► ci-ctl qube ── qrexec ci.Dom0Shell ──► dom0
                              (on the NUC, behind sys-firewall)        runs tests
```

How it fits together:

- **dom0 stays off the network.** A standalone qube, `ci-ctl`, dials out to
  the runner and keeps a reverse SSH tunnel open. Nothing needs port
  forwarding through sys-net or sys-firewall. ci-ctl is made from a Debian
  template. Fedora templates enforce SELinux, which blocks the tunnel
  service from running `ssh`.
- **The runner reaches dom0 through ci-ctl.** It SSHes into ci-ctl over the
  tunnel. A qrexec policy lets ci-ctl, and only ci-ctl, call `ci.Dom0Shell`,
  which runs a script in dom0.
- **The runner reaches guix-subs directly.** It SSHes in as `beto` to bring
  the server up to date and build the ISO.

**Status:**

- **Verified on the real machine:**
  - the unattended install from the kickstart (one F12 at first boot);
  - the first-boot CI setup;
  - the tunnel;
  - the empty-payload smoke test (runner → ci-ctl → dom0 and back);
  - SSH and passwordless sudo from the runner to guix-subs;
  - a full run by hand from the runner: ISO built on guix-subs, the
    unattended template install and update (3h10m), and `qubes-guix-test`
    on an AppVM (15 passed).
- **Not yet run:** the variants (`test-variants.sh`), `ISO_OFFLINE=1`, and
  the Gitea workflow end to end.

| File | Runs on | What it does |
|---|---|---|
| `install/make-oem-ks.sh` | your workstation | writes the kickstart file for an unattended reinstall |
| `dom0/qubes-ci-setup.sh` | dom0, once | sets up ci-ctl, the tunnel, the qrexec service and policy, autologin, nose2 |
| `dom0/run-in-dom0.sh` | dom0, each run | cleans up after the last run, installs the template, runs tests |
| `dom0/test-variants.sh` | dom0, each run | makes the HVM/PVH template, AppVM and standalone variants from the template and tests each |
| `runner/build-iso-remote.sh` | runner, each run | syncs guix-subs, builds the ISO there at the pushed commit, copies it back |
| `runner/qubes-ci-run.sh` | runner, each run | stages the payload in ci-ctl, runs dom0's part, fetches results |
| `runner/qubes-ci-reinstall.sh` | runner, on demand | wipes the NUC's bootloader and reboots it into the OEM installer |
| `../.gitea/workflows/qubes-tests.yml` | Gitea | the workflow |

## Security

This is a test rig, and parts of it are deliberately trusting. Know what
the CI key can do.

- **The CI machine:** ci-ctl has full control of dom0, through
  `ci.Dom0Shell`. Anything holding the runner's CI key can reach ci-ctl
  through the tunnel, and so can run anything in dom0. Keep personal data
  off the NUC.
- **guix-subs (accepted for now):** the CI key logs in as `beto`, and `beto`
  may run `/etc/guix-subs/build-qubes.sh` as root without a password. That
  script is owned by and writable by `beto` (`/etc/guix-subs` links into
  `~beto/proj/guix-subs`). So whoever can act as `beto` (the CI key
  included) can change the script and run anything as root: **the CI key is
  effectively root on guix-subs.** To narrow it later, either:
  - point the sudo rule at a root-owned copy:
    `sudo install -o root -g root -m 755 ~/proj/guix-subs/etc/guix-subs/build-qubes.sh /usr/local/sbin/`
    and use that path in the rule and in `ISO_SYNC_CMD`. Recopy it when the
    script changes; or
  - give the CI its own account on guix-subs, with its own qubes-guix
    clone and the sudo rule for a root-owned script, and set
    `ISO_HOST=ci@guix-subs`.
- **The runner:** guard the `ci` account and its `~/.ssh/qubes_ci_ed25519`
  accordingly. The `qubesci-tunnel` account has no shell. Its one key may
  only open the tunnel's listener (`restrict,port-forwarding,permitlisten`).
- **ci-ctl's host key isn't checked.** It changes with every reinstall, and
  only the tunnel key can open the forwarded port, so that key is what
  vouches for the connection.

## 1. NUC BIOS (F2 at power-on)

- **Security → Intel VT-x and VT-d:** on. Qubes needs both.
- **Secure Boot:** off.
- **Power → After Power Failure:** Power On. A smart plug can then
  hard-reset a hung machine.
- **Boot priority:** internal disk first, USB second. This is what makes the
  remote reinstall work.
- **No monitor:** the NUC boots headless. Keep a dummy HDMI plug in it if
  the GUI tests misbehave without a display.

The I219-V Ethernet and AX201 Wi-Fi go to sys-net and the USB controllers
to sys-usb as usual. With working VT-d nothing special is needed.

## 2. The runner and guix-subs

The runner is a small always-on machine on the LAN: here, a Debian trixie
LXC on Proxmox. It builds nothing itself; the ISO is built on guix-subs
over SSH. The NUC dials *in* to the runner, so the runner needs a stable
address and an SSH server.

It has two accounts with separate jobs:

| Account | Shell | What it's for |
|---|---|---|
| `ci` | bash | runs act_runner and the CI scripts; holds the CI key, which opens ci-ctl and `beto@guix-subs` |
| `qubesci-tunnel` | none | ci-ctl's tunnel logs in here; it can only open the 2222 listener |

Don't run the CI as root or as `qubesci-tunnel`.

**On the runner, as root:**

```sh
apt install -y git openssh-server openssh-client nodejs   # node: actions/checkout and upload-artifact

useradd -m -s /bin/bash ci
useradd -m -s /usr/sbin/nologin qubesci-tunnel
install -d -m 700 -o qubesci-tunnel -g qubesci-tunnel ~qubesci-tunnel/.ssh

# the CI key, in the ci account
sudo -u ci ssh-keygen -t ed25519 -N '' -f ~ci/.ssh/qubes_ci_ed25519
```

The line for `~qubesci-tunnel/.ssh/authorized_keys` comes from step 3. Keep
that file mode 600 and owned by `qubesci-tunnel`.

**`/etc/qubes-ci/runner.env`** on the runner. All of it is optional except
`ISO_HOST`, which has to name the guix-subs account:

```sh
ISO_HOST=beto@guix-subs         # the full DNS name if the short one doesn't resolve
ISO_DIR=proj/qubes-guix         # the checkout on guix-subs, under beto's home
TUNNEL_PORT=2222
ISO_OFFLINE=1                   # ISO with the channels' checkouts: no clone at install (recommended)
# ISO_SYNC_CMD=...              # default: guix-subs' build script via sudo; empty skips it
```

**On guix-subs, as `beto`:**

- **Key:** add the runner's `~ci/.ssh/qubes_ci_ed25519.pub` to
  `~/.ssh/authorized_keys`.
- **Checkout:** `~/proj/qubes-guix` (a clone from GitHub) is used as is.
  The build only fetches into it and works in a throwaway git worktree
  under `~/ci-iso/`, so its branch and any local work are untouched.
- **Build script:** `/etc/guix-subs/build-qubes.sh` is what the CI runs.
  (Make sure no stray links like `/etc/quix-subs` exist, and that the system
  config doesn't make one.) It runs as root: as `beto` it fails at
  `guix pull` on `/root/.cache`.
- **Sudo:** before building, the runner brings the server up to date with
  `sudo -n /etc/guix-subs/build-qubes.sh 2>&1 | sudo -n tee -a /var/log/qubes-builds.log`.
  That needs passwordless sudo for those two commands. Read
  [Security](#security) first. In guix-subs' `operating-system`:

  ```scheme
  (sudoers-file
   (plain-file "sudoers"
     (string-append (plain-file-content %sudoers-specification)
       "beto ALL=(root) NOPASSWD: /etc/guix-subs/build-qubes.sh, "
       "/run/current-system/profile/bin/tee -a /var/log/qubes-builds.log\n")))
  ```

**Check it, from the runner as `ci`.** The first command also accepts
guix-subs' host key, which the CI's `BatchMode` connections can't do
themselves:

```sh
sudo -iu ci
ssh -i ~/.ssh/qubes_ci_ed25519 beto@guix-subs true
ssh -i ~/.ssh/qubes_ci_ed25519 beto@guix-subs \
    'sudo -n -l /etc/guix-subs/build-qubes.sh && echo "passwordless sudo OK"'
```

`sudo -l` with a command only asks whether it's allowed. Don't test with
`build-qubes.sh --help`: the script ignores its arguments and runs a full
server build.

## 3. Install Qubes on the NUC

**Unattended (recommended): OEM kickstart**

1. On your workstation:

   ```sh
   DISK=nvme0n1 CI_USER=user TIMEZONE=Australia/Brisbane \
     ci/install/make-oem-ks.sh ~/qubes-ci-oem/ks.cfg runner.lan qubesci-tunnel qubes_ci_ed25519.pub
   ```

   - `runner.lan` is the runner's address, as the NUC will reach it.
   - The last argument is the runner's CI public key
     (`~ci/.ssh/qubes_ci_ed25519.pub`).
   - It prints an `authorized_keys` line. Put it in
     `~qubesci-tunnel/.ssh/authorized_keys` on the runner.
   - It also creates `~/qubes-ci-oem/qubes_ci_tunnel`. Keep it: every
     reinstall reuses it, so that line stays valid.
   - The kickstart lays out **unencrypted** partitions explicitly. Qubes'
     installer would otherwise encrypt the disk and ask for a passphrase.
     It installs only the **Debian** template, as the default.
2. **Stick A:** write `Qubes-R4.3.x-x86_64.iso` to it with `dd`.
3. **Stick B:** format it ext4 with the label `QUBES_OEM`
   (`mkfs.ext4 -L QUBES_OEM /dev/sdX1`) and copy `ks.cfg` onto it.
   Regenerate and recopy `ks.cfg` whenever `make-oem-ks.sh` or
   `qubes-ci-setup.sh` changes: the setup script is embedded in it.
4. Plug both into the NUC and boot from stick A. Choose the installer's
   **OEM install** entry; it appears when a `QUBES_OEM` partition is present.
   The install then runs unattended and **wipes `$DISK`**. The kickstart
   only uses `$DISK`, so the sticks are left alone.
5. **First boot:** the Qubes setup screen appears pre-filled from the
   kickstart: the Debian template, sys-net, sys-firewall, sys-usb. Press
   **F12** (Finish Configuration). Upstream's own OEM test also does this
   step by hand; it can't be skipped through kickstart alone.
6. **CI setup:** after first-boot setup, `qubes-ci-firstboot.service` runs
   `qubes-ci-setup.sh` by itself. It takes a few minutes, mostly creating
   ci-ctl and installing its packages.
   - The log is `/var/lib/qubes-ci/setup.log` in dom0.
   - `/var/lib/qubes-ci/setup-done` appears when it's done.
   - The tunnel then comes up, and on the runner (as `ci`)
     `ssh -i ~/.ssh/qubes_ci_ed25519 -p 2222 user@127.0.0.1 hostname` works.

Leave both sticks plugged in for later reinstalls.

**If the CI setup didn't run** (`/var/lib/qubes-ci/` is empty, or there's no
`qubes-ci-firstboot` in `systemctl list-unit-files`), start it by hand in
dom0:

```sh
sudo systemctl enable --now --no-block qubes-ci-firstboot.service
sudo tail -f /var/lib/qubes-ci/setup.log
```

The script picks up where a failed run stopped: an existing ci-ctl is
reused. The installer's own post-install step runs `systemctl preset-all`,
which disabled the unit before it was given a preset. Kickstarts made with
the current `make-oem-ks.sh` have the preset.

**By hand (if the OEM entry gives trouble)**

1. Install normally with **no disk encryption**. A LUKS prompt would stop
   unattended reboots. Install the Debian template.
2. Copy `dom0/qubes-ci-setup.sh` and the runner's CI public key into dom0.
   From a qube: `qvm-run -p <qube> 'cat file' > file` in dom0.
3. Run:

   ```sh
   sudo bash qubes-ci-setup.sh runner.lan qubesci-tunnel qubes_ci_ed25519.pub
   ```

   It prints the `authorized_keys` line for the runner.

**Notes on `qubes-ci-setup.sh`:**

- **ci-ctl's template:** ci-ctl is cloned from the newest installed
  `debian-*` template. Set `CTL_TEMPLATE` to choose another.
- **ci-ctl's private volume** (its home, where each run stages the ~3 GB
  ISO) is grown to 32 GiB; set `CTL_PRIVATE_SIZE` for another size. By hand:
  `qvm-volume resize ci-ctl:private 32GiB` in dom0. The ISO stays there
  for the install (dom0 never gets a copy) until the next run replaces it.
- **Package installs in ci-ctl** use apt when it's there. Debian templates
  also ship a `dnf` (for downloading dom0 updates), so dnf only counts on
  templates without apt.
- **nose2 is installed last, and its failure is only a warning.** dom0
  installs it through the UpdateVM, which needs working dnf tooling, and a
  Debian-based sys-firewall may not have it. Only the opt-in Qubes test
  modules need nose2.

## 4. Gitea runner

As `ci` on the runner (`sudo -iu ci`), download `act_runner` from Gitea's
releases. Then:

```sh
./act_runner generate-config > config.yaml
./act_runner register --instance https://gitea.lan --token <token> --labels qubes:host --no-interactive
./act_runner daemon --config config.yaml       # first by hand; then the unit below
```

Get the token from Repo Settings → Actions → Runners. Actions must also be
enabled for the repo. If you registered as another user, move `.runner`
(the registration) and `config.yaml` into `~ci`.

**No Docker needed.** `qubes:host` jobs run directly on the runner. The
daemon only wants Docker if it has a `docker://` label, and the generated
defaults are docker labels. Set this in `config.yaml`, which overrides the
labels saved at registration:

```yaml
runner:
  capacity: 1
  labels:
    - "qubes:host"
```

**As a service**, `/etc/systemd/system/act_runner.service`:

```ini
[Unit]
Description=Gitea act_runner (qubes CI)
After=network-online.target
Wants=network-online.target

[Service]
User=ci
WorkingDirectory=/home/ci
ExecStart=/home/ci/act_runner daemon --config /home/ci/config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
```

Then `systemctl daemon-reload && systemctl enable --now act_runner`.

**Smoke tests without Gitea**, as `ci` from a checkout (e.g.
`~/proj/qubes-guix`):

```sh
# 1. runner → ci-ctl → dom0 and back, nothing built (a few seconds)
mkdir -p /tmp/payload && ci/runner/qubes-ci-run.sh /tmp/payload /tmp/results

# 2. the full run: build the ISO on guix-subs, then install and test (an hour or more)
git pull
ci/runner/build-iso-remote.sh main "$(git rev-parse HEAD)" /tmp/payload/qubes-guix-installer.iso
cp -r dom0 /tmp/payload/ && ci/runner/qubes-ci-run.sh /tmp/payload /tmp/results
```

A good first one ends with `QUBES_CI_EXIT=0` and `results in /tmp/results,
exit 0`. The full run needs the commit pushed: the ISO is built from the
public repository.

## What a run does

1. **Waits for the mirror.** The ISO is built from the channel's public
   repository, so the workflow waits until the Gitea push mirror has the
   commit on GitHub.
2. **Builds the ISO on guix-subs** (`runner/build-iso-remote.sh`):
   - fetches the commit into `~/proj/qubes-guix`;
   - runs `/etc/guix-subs/build-qubes.sh` through sudo, so the server's
     last-built commits are at the head;
   - in a worktree at that commit, runs `iso/qubes-guix-iso -b BRANCH
     --qubes-commit SHA --server <first url in dom0/qubes-guix-substitutes>`.
     qubes is exactly the pushed commit, and the other channels are at what
     the server just built;
   - copies the ISO back to the runner.
3. **Assembles the payload:** the ISO plus the repo's `dom0/` directory
   (`qubes-guix-create`, `qubes-guix-test` and their package, channel and
   substitute files), and `ci/dom0-tests.sh` if you add one.
4. **Waits up to 10 min for the tunnel** (e.g. while the NUC reboots).
5. **Copies** `run-in-dom0.sh` and the payload into `~/ci-run/` in ci-ctl.
6. **In dom0**, through `ci.Dom0Shell`:
   - pulls `~/ci-run` from ci-ctl, all but the ISO (failing the run if
     that copy fails);
   - removes leftovers: `test-inst-*`, `test-cls-*` and `test-guix-*`
     qubes, the previous `ci-guix` template and everything named
     `ci-guix-*` (the variants), AppVMs before templates, and any RPM
     templates from the previous run;
   - if dom0 has no `pvgrub2-pvh`, tries `qubes-dom0-update -y
     grub2-xen-pvh` once (not fatal);
   - runs `qubes-guix-create --yes --unattended --template --no-password
     --force --test ci-guix ci-ctl:<the ISO>`, reading the ISO where it
     is, in ci-ctl. If an ISO was sent but isn't there, the run fails.
     `--yes` skips its "Go ahead?" question, which has no terminal here. It installs the template, does
     its first update, and runs `qubes-guix-test` on a throwaway AppVM. The
     output streams to the job log. If it fails, the installer's log is
     saved as `results/qubes-guix-install.log`. A failed install isn't
     resumed: the installer is left with nothing on root's `PATH`, so
     `qubes-guix-create` can't resume it, and the next run starts over.
     Without `ISO_OFFLINE=1` the install fetches the channels' git checkouts
     (Guix from Codeberg, ~300 MB), the most likely thing to fail;
   - if the install passed, runs `test-variants.sh` (below);
   - installs each `*.rpm` with `qvm-template install` (not used by
     qubes-guix, kept for completeness);
   - runs each `SYSTEM_TESTS` module with nose2, the way Qubes' openQA does,
     restricted to the installed templates via `QUBES_TEST_TEMPLATES`. None
     run by default;
   - runs `dom0-tests.sh`, if one is present;
   - pushes `results/` back to ci-ctl.
7. **Fetches the results:** `qubes-guix-create.log`, logs, JUnit XML, the
   dom0 journal, Xen and qube consoles, and the full console output.

**The variants** (`test-variants.sh`), for each boot mode: HVM, and PVH
when dom0 has `/var/lib/qubes/vm-kernels/pvgrub2-pvh`:

| Variant | Made by | Tested with |
|---|---|---|
| `MODE-template` | `ci-guix` itself for the mode it's in, else `qvm-clone` to `ci-guix-MODE`, switched to MODE | `qubes-guix-test --in-place` |
| `MODE-appvm` | `qubes-guix-create --appvm T --MODE --test ci-guix-app-MODE` | its `--test` |
| `MODE-standalone` | `qvm-create --class StandaloneVM --template T ci-guix-sa-MODE` (a copy of the template's disk), with the template's settings | `qubes-guix-test` |

- **Results:** each one's output goes to the job log and
  `results/variant-MODE-KIND.log`; the table of PASS/FAIL/SKIP to
  `results/variants-summary.txt`.
- **What they cover:** how each kind of qube runs. They don't cover
  `qubes-guix-create --unattended`'s own StandaloneVM or PVH install paths;
  only the template install runs on every push.
- **No `pvgrub2-pvh`:** the PVH variants are reported as SKIP, not
  failures. If the automatic `qubes-dom0-update` doesn't manage it, install
  `grub2-xen-pvh` in dom0 by hand.
- **Turning them off:** set `VARIANTS=0` in the runner's environment to run
  only the install and its test.

**Expect a long run.** A run includes the guix-subs sync build, the ISO
build and a full Guix install and update, so expect several hours (the
first full run took a little over 3), plus a few minutes per variant,
depending on how much comes from your substitute server.

**Qubes test modules** are opt-in: give them in the workflow's
`system_tests` input when you run it by hand. Upstream's tests make AppVMs
with Qubes' default settings. Guix AppVMs need HVM, the template's kernel
and more memory (see `qubes-guix-create --appvm`), so expect failures from
that rather than from qubes-guix itself. They also need nose2 in dom0 (see
step 3's notes).

Useful modules (from upstream's job definitions; timeouts in seconds):

- `qubes.tests.integ.basic`
- `qubes.tests.integ.vm_qrexec_gui:14400`
- `qubes.tests.integ.network:21600`
- `qubes.tests.integ.dispvm`
- `qubes.tests.integ.vm_update`
- `qubes.tests.integ.backup`
- `qubes.tests.integ.devices_pci`
- `qubes.tests.integ.audio`

On real hardware the PCI, USB and audio tests can work, unlike in a VM.

## Resetting the machine

- **Between runs:** cleanup is automatic (step 6 of the run). dom0 itself
  isn't rolled back, so a test that breaks dom0 needs a reinstall.
- **Full reinstall:** as `ci` on the runner, run
  `ci/runner/qubes-ci-reinstall.sh --yes-wipe-the-ci-machine`.
  - It deletes Qubes' EFI boot entry and bootloader files and reboots.
  - The firmware then falls through to the USB sticks, and the OEM install
    runs again.
  - Someone has to press F12 once at first boot.
  - The tunnel key is reused, so the runner needs no changes afterwards.

## Known rough edges

- **GUI tests** need the autologin X session. If they fail with "cannot
  open display", check `loginctl` in dom0. Try a dummy HDMI plug.
- **Template network:** ci-ctl, the template under test and the test qubes
  all use the normal sys-net → sys-firewall path, so anything they download
  goes out through your LAN.
- **One machine:** runs queue behind each other (capacity 1, plus the
  workflow's `concurrency` group).
