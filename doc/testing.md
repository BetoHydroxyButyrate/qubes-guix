# Testing a qube

[← README](../README.md)

`dom0/qubes-guix-test` (`qg-test`, once `qubes-guix-refresh` has put the dom0 scripts in place) smoke-tests a Guix qube's Qubes integration and prints PASS, FAIL or SKIP for each check; its exit status is the number of failures. Given a template, it makes a throwaway AppVM from it (`test-guix-<pid>`), tests that, and removes it; `--in-place` tests the template itself instead (without a netvm, the network checks are skipped). `--keep` leaves the qube tested running afterwards, and keeps a throwaway AppVM. Any other Guix qube is tested in place. It only touches the qube under test, so it's safe on a daily-use dom0.

```
qubes-guix-test guix-tmpl                         # template: via a throwaway AppVM
qubes-guix-test --in-place guix-tmpl              # the template itself
qubes-guix-test --split-gpg --split-ssh guix-tmpl # also the vault clients
qubes-guix-create --unattended --template --test …   # the same, after an install
```

It checks: start and boot time; qrexec; QubesDB; the features the agent requested; failed Shepherd services; network (address, gateway, DNS and HTTPS); the network coming back after the netvm is detached and reattached (as when the netvm restarts); 1 MiB through qrexec each way, checksummed; `qvm-copy-to-vm` (`qubes.Filecopy`); the trusted-channels link; memory balancing (meminfo in xenstore); the USB proxy (`qubes.USBAttach` and the `vhci-hcd` module present: no device is attached); block devices for dom0 (a loop device made in the qube is listed by `qvm-block`, and goes again); a terminal window appearing in dom0; split-gpg2 and split-ssh (optional); and a clean shutdown.

Qubes' own integration tests (`qubes.tests.integ` in dom0, `QUBES_TEST_TEMPLATES=…`) can also run against a Guix template, but they stop qubesd and create and remove qubes: run them only on a machine set aside for testing. Their distribution-specific parts (updates) don't apply to Guix.
