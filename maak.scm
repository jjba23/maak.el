;; maak.scm --- the tasks of maak.el itself.

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:
;;
;; maak.el is Emacs Lisp, so its tasks are batch Emacs runs: the suite, the
;; byte compiler, and the two together as `ci'.  `maak' with no task lists
;; them, which is what `default' does here as well.
;;
;; The suite is run with the project directory on the load path, so it tests
;; this checkout rather than an installed maak.el.

;;; Code:

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak)
  ;; The container helpers are imported under a prefix because the exported
  ;; tasks below are named the way maak exposes them on the command line --
  ;; `maak container-build' -- and a task may not shadow the helper it calls.
  #:use-module ((maak container) #:prefix ct:)
  #:export (default test byte-compile ci container-build container-run package-docker))

;; A value definition, not a task: maak.el's parser has to leave it out too.
(define emacs-batch-command
  (list "emacs" "-Q" "--batch" "-L" "."))

(define (default)
  "List the tasks this project defines."
  (list-tasks))

(define* (test #:optional pattern)
  "Run the ERT suite in batch mode.
With PATTERN, run only the tests whose names match it."
  (run (append emacs-batch-command
               (list "-l" "test/maak-test.el")
               (if pattern
                   (list "--eval"
                         (format #f "(ert-run-tests-batch-and-exit ~s)" pattern))
                 (list "-f" "ert-run-tests-batch-and-exit")))
       #:verbose? #t))

(define (byte-compile)
  "Byte-compile maak.el, with warnings treated as errors."
  (run (append emacs-batch-command
               (list "--eval" "(setq byte-compile-error-on-warn t)"
                     "-f" "batch-byte-compile" "maak.el"))
       #:verbose? #t)
  (when (file-exists? "maak.elc")
    (delete-file "maak.elc")))

(define (ci)
  "Byte-compile and test, the way continuous integration does."
  (byte-compile)
  (test))

;; ====== Container tasks ======

(define (container-build)
  "Build the container image for maak-el."
  (ct:container-build "." #:tag "maak-el" #:verbose? #t))

(define (container-run)
  "Run the container image for maak-el."
  (ct:container-run "maak-el:latest"
                    #:interactive? #t
                    #:tty? #t))

(define (package-docker)
  "Build the container image for maak-el."
  (container-build))
