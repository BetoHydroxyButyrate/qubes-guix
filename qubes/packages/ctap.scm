;;; qubes/packages/ctap.scm — qubes-app-u2f (python module "qubesctap").
;;;
;;; Guest frontend only: qctap-proxy creates a virtual FIDO HID device via
;;; /dev/uhid and forwards each CTAP1/CTAP2 request to the backend qube
;;; (sys-usb) over qrexec: ctap.GetInfo, ctap.ClientPin, u2f.Register,
;;; u2f.Authenticate+<key-handle-hash>. The sys_usb/ half (qctap-get-info,
;;; ...) ships in the module but no launchers are installed for it.

(define-module (qubes packages ctap)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix build-system pyproject)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages check)            ; python-pytest, -asyncio
  #:use-module (gnu packages python-build)     ; setuptools, wheel, packaging
  #:use-module (gnu packages security-token)   ; python-fido2
  #:use-module (qubes packages qrexec))

(define-public qubes-ctap
  (package
    (name "qubes-ctap")
    (version "2.0.7")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/QubesOS/qubes-app-u2f")
             (commit "941f0d5a6a0533c60bb03881e0efa5835e2f7b9d"))) ; v2.0.7
       (file-name (git-file-name name version))
       (sha256
        (base32 "1frvcvc265xrqvq1rw48jp9i2fmakhg8vyf725njdv0pzfgl4md6"))))
    (build-system pyproject-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          ;; CustomInstall writes launchers to <root>/usr/bin; we install
          ;; our own below instead.
          (add-after 'unpack 'drop-custom-install
            (lambda _
              (substitute* "setup.py"
                (("'install': CustomInstall,") ""))))
          (add-after 'unpack 'patch-qrexec-client
            (lambda* (#:key inputs #:allow-other-keys)
              (substitute* "qubesctap/const.py"
                (("'/usr/bin/qrexec-client-vm'")
                 (string-append "'" (search-input-file
                                     inputs "/usr/bin/qrexec-client-vm")
                                "'")))))
          ;; Upstream bug (v2.0.7, still on master): every CTAPHID reply is sent
          ;; as CTAPHID_MSG, even for a CTAPHID_CBOR request. Spec-strict
          ;; clients (python-fido2: "INVALID_COMMAND") reject that; lenient
          ;; ones may cope. Reply with the request's command.
          (add-after 'unpack 'cbor-reply-command
            (lambda _
              (substitute* "qubesctap/client/hidemu.py"
                (("await self\\.write_ctaphid_response\\(cid, CTAPHID\\.MSG,")
                 "await self.write_ctaphid_response(cid, CTAPHID.CBOR if ctaphid == \"cbor\" else CTAPHID.MSG,"))))
          ;; Upstream bug: CTAP2 makes rp.name optional in makeCredential,
          ;; but python-fido2 (1.x and 2.x) requires it, so a request without
          ;; one (Firefox sends that) fails with "Error parsing field rp"
          ;; (0x6A80) -- here, and again in sys-usb. Default name to id;
          ;; the request is re-encoded, so sys-usb gets the name too.
          (add-after 'unpack 'default-rp-name
            (lambda _
              (substitute* "qubesctap/ctap2.py"
                (("( +)cbor_request = cbor\\.decode\\(untrusted_cbor\\) if untrusted_cbor else \\{\\}"
                  all indent)
                 (string-append
                  all "\n"
                  indent "rp = cbor_request.get(2) if req_type == 1 and isinstance(cbor_request, dict) else None\n"
                  indent "if isinstance(rp, dict) and \"name\" not in rp and isinstance(rp.get(\"id\"), str):\n"
                  indent "    cbor_request[2] = {**rp, \"name\": rp[\"id\"]}")))))
          ;; Before 'wrap, so the launcher gets GUIX_PYTHONPATH.
          (add-after 'install 'install-launcher
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (mkdir-p bin)
                (call-with-output-file (string-append bin "/qctap-proxy")
                  (lambda (port)
                    (format port "#!~a
from qubesctap.client.qctap_proxy import main
import sys
if __name__ == '__main__':
    sys.exit(main())
" (which "python3"))))
                (chmod (string-append bin "/qctap-proxy") #o755))))
          ;; test_systemd_notify binds a unix socket under pytest's tmp
          ;; dir; the build dir path pushes it past the 108-byte
          ;; sun_path limit ("AF_UNIX path too long"), so use a short one.
          (replace 'check
            (lambda* (#:key tests? #:allow-other-keys)
              (when tests?
                (invoke "python3" "-m" "pytest" "-q"
                        "--basetemp=/tmp/qctap" "qubesctap/tests")))))))
    (native-inputs
     (list python-setuptools python-wheel python-pytest python-pytest-asyncio))
    (inputs (list qubes-core-qrexec))
    (propagated-inputs (list python-fido2 python-packaging))
    (home-page "https://github.com/QubesOS/qubes-app-u2f")
    (synopsis "Qubes OS CTAP/U2F proxy (frontend)")
    (description
     "@command{qctap-proxy} presents a virtual FIDO security key to local
applications via @file{/dev/uhid} and forwards every request over qrexec to
the qube that holds the real USB key (normally @code{sys-usb}).  Upstream
qubes-app-u2f, tested here against python-fido2 2.x.")
    (license license:gpl2+)))
