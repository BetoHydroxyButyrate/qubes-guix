;; ~/.config/guix/channels.scm with the qubes channel, as installed by
;; qubes-guix-setup. Commits are signed; guix pull verifies them.
(cons* (channel
        (name 'qubes)
        (url "https://github.com/BetoHydroxyButyrate/qubes-guix")
        (branch "main")
        (introduction
         (make-channel-introduction
          "ea33fcb13bff41db38017f9ec385565f66f88fae"
          (openpgp-fingerprint            ; the signing SUBKEY (see .guix-authorizations)
           "1607 721B 3110 F370 9497  F436 B548 D5A5 665F D366"))))
       %default-channels)
