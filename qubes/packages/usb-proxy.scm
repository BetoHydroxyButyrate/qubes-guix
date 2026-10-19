;;; qubes/packages/usb-proxy.scm — qubes-usb-proxy (qubes-app-linux-usb-proxy).
;;;
;;; The frontend: lets dom0 attach a USB device from sys-usb to this qube
;;; (qvm-usb attach, the devices widget). dom0 calls qubes.USBAttach here as
;;; root with "BACKEND BUSID"; it connects to BACKEND's qubes.USB+BUSID over
;;; qrexec and hands that connection to the kernel's USB/IP virtual host
;;; controller (vhci-hcd), so the device appears here as a local USB device.
;;; Detaching is done on the backend (its qubes.USBDetach); the connection
;;; ends and the device goes. Without qubes.USBAttach, dom0 says
;;; "qubes-usb-proxy not installed in the VM".
;;;
;;; Only the frontend is packaged: a Guix qube as the USB backend (sys-usb)
;;; would need usb-export, usbip-host and the udev rules.

(define-module (qubes packages usb-proxy)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)          ; coreutils, grep
  #:use-module (gnu packages bash)
  #:use-module (gnu packages linux)         ; kmod, eudev
  #:use-module (qubes packages qrexec))

(define-public qubes-usb-proxy
  (package
    (name "qubes-usb-proxy")
    (version "4.3.7")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-app-linux-usb-proxy")
             (commit "7a65774a14fff4d6e6dd3cfecfcf2c7a6c43e02a"))) ; v4.3.7
       (file-name (git-file-name name version))
       (sha256
        (base32 "1sgsm1bk2vnl6whihrsay5riskk71cm205bd7qxawg8b18gpvvgy"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (delete 'build)
          (replace 'install
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((rpc     (string-append #$output "/etc/qubes-rpc"))
                     (lib     (string-append #$output "/lib/qubes"))
                     (bash    (search-input-file inputs "/bin/bash"))
                     (qrexec  (search-input-file inputs
                                                 "/usr/bin/qrexec-client-vm"))
                     (modprobe (search-input-file inputs "/bin/modprobe"))
                     (udevadm (search-input-file inputs "/bin/udevadm"))
                     ;; usb-import's tools: grep, sort, uname, sleep, rm.
                     (path    (string-join
                               (map (lambda (p)
                                      (dirname (search-input-file inputs p)))
                                    '("/bin/grep" "/bin/sort"))
                               ":"))
                     (prelude (string-append "#!" bash "\n"
                                             "PATH=" path "\n"
                                             "export PATH\n")))
                (mkdir-p rpc)
                (mkdir-p lib)
                ;; Upstream's '#!/bin/sh' scripts use bash ([[ ]], local).
                (install-file "src/usb-import" lib)
                (substitute* (string-append lib "/usb-import")
                  (("^#!.*") prelude)
                  ;; Guix's modprobe looks in LINUX_MODULE_DIRECTORY, which
                  ;; qrexec services don't have.
                  (("if command -v modprobe >/dev/null; then modprobe vhci-hcd; fi")
                   (string-append
                    "LINUX_MODULE_DIRECTORY=/run/booted-system/kernel/lib/modules "
                    modprobe " vhci-hcd || "
                    "{ echo \"vhci-hcd: no USB/IP module in this kernel\" >&2; exit 1; }"))
                  (("`hostname`") "$(cat /proc/sys/kernel/hostname)")
                  (("\\[ -f \"/usr/bin/udevadm\" \\] && udevadm settle")
                   (string-append udevadm " settle")))
                (install-file "src/usb-detach-all" lib)
                (substitute* (string-append lib "/usb-detach-all")
                  (("^#!.*") prelude))
                (for-each
                 (lambda (svc)
                   (install-file (string-append "qubes-rpc/" svc) rpc)
                   (substitute* (string-append rpc "/" svc)
                     (("^#!.*") prelude)
                     (("^qrexec-client-vm ") (string-append qrexec " "))
                     (("/usr/lib/qubes/") (string-append lib "/"))))
                 '("qubes.USBAttach" "qubes.USBDetach"))
                (for-each (lambda (f) (chmod f #o755))
                          (append (find-files rpc) (find-files lib)))
                (install-file "README.md"
                              (string-append #$output
                                             "/share/doc/qubes-usb-proxy"))))))))
    (inputs
     (list bash-minimal coreutils grep kmod eudev qubes-core-qrexec))
    (home-page "https://github.com/QubesOS/qubes-app-linux-usb-proxy")
    (synopsis "Qubes USB proxy: attach USB devices from sys-usb to this qube")
    (description
     "The qube side of the Qubes USB proxy: @code{qubes.USBAttach} connects
over qrexec to the USB backend qube (sys-usb) and attaches the device it
exports to the kernel's USB/IP virtual host controller (@code{vhci-hcd}), so
@command{qvm-usb attach} and the devices widget work for this qube.")
    (license license:gpl2+)))
