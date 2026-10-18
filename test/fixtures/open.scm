;;; open.scm --- a Maak file with no export list, so every procedure is a task.

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:
;;
;; There is no `#:export' here on purpose: maak then treats every top-level
;; procedure as a task, which is the open fallback.  The file is read by the
;; parser tests only, so it holds constructs that are easiest to keep out of a
;; file Guile also loads.

;;; Code:

(define-module (maak)
  #:declarative? #t)

(define (alpha)
  "The first task."
  'alpha)

(define (undocumented value)
  value)

(define (outer)
  "An outer task that defines a helper in its body."
  (define (inner)
    "The helper belongs to the body, not to the task list."
    'inner)
  (inner))

(define (documented)
  "First line.
Second line."
  #t)

;; A value definition is not a procedure, so it is not a task.
(define not-a-procedure (make-parameter 1))

(define* (commented-signature #| a block comment between arguments |#
                              #:optional (maybe 1))
  "An argument list with a block comment in it."
  maybe)

(define* (datum-commented #;ignored #:optional (value 2))
  "An argument list with a datum comment in it."
  value)

(define (escaped-quote)
  "A docstring with a \"quoted\" word."
  #t)

(define (redefined)
  "The first definition."
  'first)

(define (redefined)
  "The last definition wins."
  'second)
