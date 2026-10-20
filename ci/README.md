# Qubes OS 4.3 CI on a bare-metal NUC

A dedicated Intel NUC (NUC10FNH) runs Qubes OS 4.3. On every push, Gitea
Actions copies the qubes-guix template into it, runs Qubes' own integration
tests against the template plus our own dom0 tests, and collects the results.

```
Gitea ──► act_runner (runner host, LAN)  ◄──── reverse SSH tunnel ────┐
             │ ssh -p 2222 127.0.0.1                                  │
             └──────────────► ci-ctl qube ── qrexec ci.Dom0Shell ──► dom0
                              (on the NUC, behind sys-firewall)        runs tests
```

How it fits together:

- **dom0 stays off the network.** A standalone qube, `ci-ctl`, dials out to
  the runner and keeps a reverse SSH tunnel open. Nothing needs port
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

Any always-on Linux machine on the LAN: a small VM on TrueNAS works. The
NUC dials *in* to it, so the runner needs a stable address. On it:

```sh
apt install -y git jq openssh-server nodejs   # node: needed by actions/checkout in host mode

# the user the CI job runs as: its key logs in to ci-ctl
ssh-keygen -t ed25519 -N '' -f ~/.ssh/qubes_ci_ed25519

# the user ci-ctl's tunnel logs in as: may only open the 2222 listener
sudo useradd -m -s /usr/sbin/nologin qubesci-tunnel
sudo install -d -m 700 -o qubesci-tunnel -g qubesci-tunnel ~qubesci-tunnel/.ssh
```

The line for `~qubesci-tunnel/.ssh/authorized_keys` comes from step 3.

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
   kickstart (templates, sys-net, sys-firewall, sys-usb). Press **F12**
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
./act_runner generate-config > config.yaml     # set runner.capacity: 1
./act_runner register --instance https://gitea.lan --token <token> --labels qubes:host --no-interactive
./act_runner daemon --config config.yaml       # make it a systemd service once it works
```

Get the token from Repo Settings → Actions → Runners. Actions must also be
enabled for the repo. Then replace the **Build payload** step in
`.gitea/workflows/qubes-tests.yml` with the real template build.

**Smoke test without Gitea:**

```sh
mkdir /tmp/payload
SYSTEM_TESTS=qubes.tests.integ.basic ci/runner/qubes-ci-run.sh /tmp/payload /tmp/results
```

## What a run does

1. Waits up to 10 min for the tunnel (e.g. while the NUC reboots).
2. Copies `run-in-dom0.sh` and the payload into `~/ci-run/` in ci-ctl.
3. In dom0, through `ci.Dom0Shell`:
   - pulls `~/ci-run` from ci-ctl;
   - removes leftover `test-inst-*` and `test-cls-*` qubes, and the
     templates installed by the previous run;
   - installs each `*.rpm` with `qvm-template install`;
   - runs each `SYSTEM_TESTS` module with nose2, the way Qubes' openQA does,
     restricted to those templates via `QUBES_TEST_TEMPLATES`;
   - runs `dom0-tests.sh`, if one is present;
   - pushes `results/` back to ci-ctl.
4. Fetches the results: logs, JUnit XML, the dom0 journal, Xen and qube
   consoles, and the full console output.

**Useful modules** (from upstream's job definitions; timeouts in seconds):

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
