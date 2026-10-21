# Qubes OS 4.3 CI on a bare-metal NUC

A dedicated Intel NUC (NUC10FNH) runs Qubes OS 4.3. On every push to
`main`, Gitea Actions:

1. builds the qubes-guix installer ISO at that commit on guix-subs
   (`iso/qubes-guix-iso`, driven over SSH);
2. on the NUC, installs a Guix template from it with `dom0/qubes-guix-create
   --unattended --template --test`, which also runs `qubes-guix-test`;
3. optionally runs Qubes' own integration test modules against the template;
4. collects the results.

```
Gitea ──► act_runner (Debian LXC)  ◄──── reverse SSH tunnel ─────────┐
             │ ssh guix-subs: build the ISO, copy it back             │
             │ ssh -p 2222 127.0.0.1                                  │
             └──────────────► ci-ctl qube ── qrexec ci.Dom0Shell ──► dom0
                              (on the NUC, behind sys-firewall)        runs tests
```

How it fits together:

- **dom0 stays off the network.** A standalone qube, `ci-ctl`, dials out to
  the runner and keeps a reverse SSH tunnel open. It's made from a Debian
  template: Fedora templates enforce SELinux, which blocks the tunnel
  service from running `ssh`. Nothing needs port
  forwarding through sys-net or sys-firewall.
- **The runner reaches dom0 through ci-ctl.** It SSHes into ci-ctl over the
  tunnel. A qrexec policy lets ci-ctl, and only ci-ctl, call `ci.Dom0Shell`,
  which runs a script in dom0.
- **That's still full control of dom0** from anything that can reach the
  runner's tunnel user and the CI key. That's fine for a machine that only
  runs tests. Keep personal data off it.

**Untested.** I couldn't run any of this; it's written from the Qubes
openQA tests and the Qubes installer and admin sources. Expect to fix things
on the first run.

| File | Runs on | What it does |
|---|---|---|
| `install/make-oem-ks.sh` | your workstation | writes the kickstart file for an unattended reinstall |
| `dom0/qubes-ci-setup.sh` | dom0, once | sets up ci-ctl, the tunnel, the qrexec service and policy, autologin, nose2 |
| `dom0/run-in-dom0.sh` | dom0, each run | cleans up after the last run, installs templates, runs tests |
| `runner/build-iso-remote.sh` | runner, each run | syncs guix-subs, builds the ISO there at the pushed commit, copies it back |
| `runner/qubes-ci-run.sh` | runner, each run | stages the payload in ci-ctl, runs dom0's part, fetches results |
| `runner/qubes-ci-reinstall.sh` | runner, on demand | wipes the NUC's bootloader and reboots it into the OEM installer |
| `../.gitea/workflows/qubes-tests.yml` | Gitea | the workflow |

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

## 2. The runner host

A small always-on Linux machine on the LAN, e.g. a Debian trixie LXC on
Proxmox. It doesn't build anything itself: the ISO is built on guix-subs
over SSH. The NUC dials *in* to the runner, so the runner needs a stable
address and an SSH server.

**On the runner:**

```sh
apt install -y git openssh-server openssh-client nodejs   # node: actions/checkout and upload-artifact

# as the user act_runner runs as: this key logs in to ci-ctl and to guix-subs
ssh-keygen -t ed25519 -N '' -f ~/.ssh/qubes_ci_ed25519
ssh -i ~/.ssh/qubes_ci_ed25519 guix-subs true     # once, to accept its host key

# the user ci-ctl's tunnel logs in as: may only open the 2222 listener
useradd -m -s /usr/sbin/nologin qubesci-tunnel
install -d -m 700 -o qubesci-tunnel -g qubesci-tunnel ~qubesci-tunnel/.ssh
```

The line for `~qubesci-tunnel/.ssh/authorized_keys` comes from step 3. The
`restrict` and `permitlisten` options in that line do the locking down.

**On guix-subs**, as the user the runner SSHes in as:

- **Key:** add the runner's `qubes_ci_ed25519.pub` to its
  `~/.ssh/authorized_keys`.
- **Checkout:** `~/proj/qubes-guix` (a clone from GitHub) is used as is. The
  build only fetches into it and works in a throwaway git worktree under
  `~/ci-iso/`, so the checkout's branch and any local work are untouched.
- **Sudo:** before building, the runner brings the server up to date with
  its own build:
  `sudo -n /etc/guix-subs/build-qubes.sh 2>&1 | sudo -n tee -a /var/log/qubes-builds.log`.
  That needs passwordless sudo for exactly those two commands. In its
  `operating-system`, using your user name:

  ```scheme
  (sudoers-file
   (plain-file "sudoers"
     (string-append (plain-file-content %sudoers-specification)
       "beto ALL=(root) NOPASSWD: /etc/guix-subs/build-qubes.sh, "
       "/run/current-system/profile/bin/tee -a /var/log/qubes-builds.log\n")))
  ```

  Or set `ISO_SYNC_CMD` to something else, or to empty to skip this step
  (see below).

**`/etc/qubes-ci/runner.env`** on the runner (all optional; these are the
defaults):

```sh
ISO_HOST=guix-subs              # or user@guix-subs.lan
ISO_DIR=proj/qubes-guix
TUNNEL_PORT=2222
```

## 3. Install Qubes on the NUC

**Unattended (recommended): OEM kickstart**

1. On your workstation:

   ```sh
   DISK=nvme0n1 CI_USER=user TIMEZONE=Australia/Brisbane \
     ci/install/make-oem-ks.sh ~/qubes-ci-oem/ks.cfg runner.lan qubesci-tunnel qubes_ci_ed25519.pub
   ```

   - The last argument is the runner's CI public key from step 2.
   - It prints an `authorized_keys` line. Put it in
     `~qubesci-tunnel/.ssh/authorized_keys` on the runner.
   - It also creates `~/qubes-ci-oem/qubes_ci_tunnel`. Keep it: every
     reinstall reuses it, so that line stays valid.
2. **Stick A:** write `Qubes-R4.3.x-x86_64.iso` to it with `dd`.
3. **Stick B:** format it ext4 with the label `QUBES_OEM`
   (`mkfs.ext4 -L QUBES_OEM /dev/sdX1`) and copy `ks.cfg` onto it.
4. Plug both into the NUC and boot from stick A. Choose the installer's
   **OEM install** entry; it appears when a `QUBES_OEM` partition is present.
   The install then runs unattended and **wipes `$DISK`**. The kickstart
   only uses `$DISK`, so the sticks are left alone.
5. **First boot:** the Qubes setup screen appears pre-filled from the
   kickstart (the Debian template only, as the default, sys-net, sys-firewall, sys-usb). Press **F12**
   (Finish Configuration). Upstream's own OEM test also does this step by
   hand. As far as I can tell it can't be skipped through kickstart alone.
6. After setup, `qubes-ci-firstboot.service` runs `qubes-ci-setup.sh` by
   itself. The log is `/var/lib/qubes-ci/setup.log` in dom0. When it's done,
   `ssh -i ~/.ssh/qubes_ci_ed25519 -p 2222 user@127.0.0.1 hostname` works on
   the runner.

Leave both sticks plugged in for later reinstalls.

**By hand (if the OEM entry gives trouble)**

1. Install normally with **no disk encryption**. A LUKS prompt would stop
   unattended reboots.
2. Copy `dom0/qubes-ci-setup.sh` and the runner's public key into dom0. From
   a qube: `qvm-run -p <qube> 'cat file' > file` in dom0.
3. Run:

   ```sh
   sudo bash qubes-ci-setup.sh runner.lan qubesci-tunnel qubes_ci_ed25519.pub
   ```

   It prints the `authorized_keys` line for the runner.

## 4. Gitea runner

Download `act_runner` from Gitea's releases onto the runner host, as the CI
user from step 2. Then:

```sh
./act_runner generate-config > config.yaml
./act_runner register --instance https://gitea.lan --token <token> --labels qubes:host --no-interactive
./act_runner daemon --config config.yaml       # make it a systemd service once it works
```

Get the token from Repo Settings → Actions → Runners. Actions must also be
enabled for the repo.

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

**Smoke test without Gitea**, from a checkout on the runner. The first
command checks the connection to dom0 without building anything:

```sh
mkdir -p /tmp/payload && ci/runner/qubes-ci-run.sh /tmp/payload /tmp/results

ci/runner/build-iso-remote.sh main "$(git rev-parse origin/main)" /tmp/payload/qubes-guix-installer.iso
cp -r dom0 /tmp/payload/ && ci/runner/qubes-ci-run.sh /tmp/payload /tmp/results
```

The next two lines build the ISO on guix-subs and run the full install and
test.

## What a run does

1. **Waits for the mirror.** The ISO is built from the channel's public
   repository, so the workflow waits until the Gitea push mirror has the
   commit on GitHub.
2. **Builds the ISO on guix-subs** (`runner/build-iso-remote.sh`):
   - fetches the commit into `~/proj/qubes-guix`;
   - runs `/etc/guix-subs/build-qubes.sh`, so the server's last-built
     commits are at the head;
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
   - pulls `~/ci-run` from ci-ctl;
   - removes leftovers: `test-inst-*`, `test-cls-*` and `test-guix-*`
     qubes, the previous `ci-guix` template, and any RPM templates from the
     previous run;
   - runs `qubes-guix-create --unattended --template --no-password --force
     --test ci-guix dom0:<the ISO>`. That installs the template, does its
     first update, and runs `qubes-guix-test` on a throwaway AppVM. The
     output streams to the job log;
   - installs each `*.rpm` with `qvm-template install` (not used by
     qubes-guix, kept for completeness);
   - runs each `SYSTEM_TESTS` module with nose2, the way Qubes' openQA does,
     restricted to the installed templates via `QUBES_TEST_TEMPLATES`. None
     run by default;
   - runs `dom0-tests.sh`, if one is present;
   - pushes `results/` back to ci-ctl.
7. **Fetches the results:** `qubes-guix-create.log`, logs, JUnit XML, the
   dom0 journal, Xen and qube consoles, and the full console output.

**Expect a long run.** A run includes a full Guix install and update, so
expect an hour or more, depending on how much comes from your substitute
server.

**Qubes test modules** are opt-in: give them in the workflow's
`system_tests` input when you run it by hand. Upstream's tests make AppVMs
with Qubes' default settings. Guix AppVMs need HVM, the template's kernel
and more memory (see `qubes-guix-create --appvm`), so expect failures from
that rather than from qubes-guix itself.

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

- **Between runs:** cleanup is automatic (step 3 above). dom0 itself isn't
  rolled back, so a test that breaks dom0 needs a reinstall.
- **Full reinstall:** run `ci/runner/qubes-ci-reinstall.sh --yes-wipe-the-ci-machine`
  from the runner.
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
