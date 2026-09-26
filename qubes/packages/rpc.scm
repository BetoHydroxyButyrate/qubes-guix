(define-module (qubes packages rpc-services)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages bash))

(define %rpc-scripts
  '("qubes.VMShell" "qubes.VMShell+WaitForSession.config"
    "qubes.VMExec" "qubes.VMExecGUI.config"
    "qubes.VMRootShell" "qubes.VMRootExec" "qubes.VMRootExec.config"
    "qubes.GetDate" "qubes.SetDateTime" "qubes.ShowInTerminal"))

(define-public qubes-rpc-services
  (package
    (name "qubes-rpc-services")
    (version "mm_47383334")
    (source (origin ...))          ; usual git-fetch + hash dance
    (build-system gnu-build-system)
    (arguments
     `(#:tests? #f
       #:phases
       (modify-phases %standard-phases
         (delete 'configure)
         (delete 'build)
         (replace 'install
           (lambda* (#:key outputs #:allow-other-keys)
             (let ((out (assoc-ref outputs "out"))
                   (dir "qubes-rpc"))
               (for-each
                (lambda (f)
                  (install-file (string-append dir "/" f)
                                (string-append out "/share/qubes-rpc")))
                ',%rpc-scripts)))))))
    (native-inputs (list bash))     ; substituted target below
    (add-after 'unpack 'fix-bash-paths
               (lambda _
		 (substitute* "qubes-rpc/qubes.VMShell"
			      (("^exec /bin/bash")
			       "exec /run/current-system/profile/bin/bash"))))    
    ...))
