;;; empty-exports.scm --- an empty export list means open season in maak.

(define-module (maak)
  #:declarative? #t
  #:export ())

(define (alpha)
  "A task, exported only because the export list is empty."
  'alpha)
