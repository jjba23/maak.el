;;; grammar.scm --- every argument form a Maak file can use.

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; This file is both a fixture for maak.el's parser and a real Maak file: the
;; tests ask Guile for the arity of each task and compare it with what maak.el
;; read, so it has to load on its own, without maak's helpers.  Every exported
;; task is one shape of argument list, and the definitions below the module
;; form are things that must not become tasks.

;;; Code:

(define-module (maak)
  #:declarative? #t
  #:export (no-args
            required-only
            optional-args
            optional-defaults
            keyword-args
            dotted-rest
            keyword-rest
            mixed
            build-all!
            lambda-task
            lambda-star-task))

(define (no-args)
  "Take no arguments at all."
  (list))

(define (required-only first second)
  "Take two required arguments."
  (list first second))

(define* (optional-args required #:optional maybe)
  "Take a required argument and one optional argument without a default."
  (list required maybe))

(define* (optional-defaults required #:optional (first "one") (second "two"))
  "Take a required argument and two optional arguments with defaults."
  (list required first second))

(define* (keyword-args required #:key (flag #t) (count 2) #:allow-other-keys)
  "Take keyword arguments, which only ever arrive as their defaults."
  (list required flag count))

(define (dotted-rest first . rest)
  "Take one required argument and a dotted rest argument."
  (cons first rest))

(define* (keyword-rest first #:rest rest)
  "Take one required argument and a #:rest argument."
  (cons first rest))

(define* (mixed required #:optional (maybe "m") #:key (flag "f") #:rest rest)
  "Take every kind of argument in one signature."
  (list required maybe flag rest))

(define* (build-all! #:optional (fast? #f))
  "A task name with punctuation in it, and a false default."
  (list fast?))

(define lambda-task
  (lambda (first second)
    "Take two required arguments, defined as a lambda value."
    (list first second)))

(define lambda-star-task
  (lambda* (required #:optional (opt 1))
    "Take a required and an optional argument, defined as a lambda* value."
    (list required opt)))

;; Everything below must stay out of the task list.

;; (define (commented-out) "A line comment hides this one." #f)
#| (define (block-commented) "A block comment hides this one." #f) |#
#;(define (datum-commented) "A datum comment hides this one." #f)

(define note "(define (fake) \"A string is not a definition.\")")

(define (hidden-helper)
  "Not exported, so it is a private helper rather than a task."
  'hidden)
