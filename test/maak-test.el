;;; maak-test.el --- ERT tests for maak.el -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:
;;
;; The tests are about the two halves of the package: reading a Maak file the
;; way maak reads it, and turning what was read into a command.  The fixture
;; `test/fixtures/grammar.scm' holds every argument form Guile accepts, and one
;; test asks Guile itself for the arity of each task, so the parser is checked
;; against the grammar rather than against a copy of it.
;;
;; Run them with:
;;
;;   emacs -Q --batch -L . -l test/maak-test.el -f ert-run-tests-batch-and-exit
;;
;; or, from a checkout, with `maak test'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst maak-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (or load-file-name buffer-file-name
         (expand-file-name "test/maak-test.el")))))
  "Root directory of the maak.el checkout.")

(add-to-list 'load-path maak-test-root)
(require 'maak)

;;; Helpers

(defun maak-test-fixture (name)
  "Return the absolute path of the fixture called NAME."
  (expand-file-name (concat "test/fixtures/" name) maak-test-root))

(defmacro maak-test-with-scheme-buffer (contents &rest body)
  "Evaluate BODY in a temporary `scheme-mode' buffer holding CONTENTS."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,contents)
     (delay-mode-hooks (scheme-mode))
     (goto-char (point-min))
     ,@body))

(defmacro maak-test-with-project (contents &rest body)
  "Evaluate BODY in a temporary project whose maak.scm holds CONTENTS.

`maak-test-project-dir' and `maak-test-project-file' name the directory and
the file while BODY runs."
  (declare (indent 1) (debug t))
  `(let* ((maak-test-project-dir
           (file-name-as-directory (make-temp-file "maak-test-project-" t)))
          (maak-test-project-file
           (expand-file-name "maak.scm" maak-test-project-dir))
          (default-directory maak-test-project-dir))
     (with-temp-file maak-test-project-file
       (insert ,contents))
     (unwind-protect
         (progn ,@body)
       (delete-directory maak-test-project-dir t))))

(defmacro maak-test-with-prompts (task-name answers &rest body)
  "Evaluate BODY with completion choosing TASK-NAME and ANSWERS as replies.

ANSWERS is a form that evaluates to a list of strings.  Asking for more answers
than that is an error, which is what makes a test notice an extra prompt.
`maak-test-prompts' holds the prompts that were shown, most recent first."
  (declare (indent 2) (debug t))
  `(let ((maak-test-answers ,answers)
         (maak-test-prompts nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (&rest _) ,task-name))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _)
                  (push prompt maak-test-prompts)
                  (unless maak-test-answers
                    (error "Unexpected prompt: %s" prompt))
                  (pop maak-test-answers))))
       ,@body)))

(defun maak-test-argument (name kind &optional keyword default default-p)
  "Build an argument plist, as `maak-get-tasks' would."
  (list :name name :kind kind :keyword keyword
        :default default :default-p default-p))

(defun maak-test-arguments (task)
  "Return a readable summary of the arguments of TASK.

Each element is (NAME KIND KEYWORD DEFAULT DEFAULT-P), which keeps a failure
message short enough to read."
  (mapcar (lambda (argument)
            (list (plist-get argument :name)
                  (plist-get argument :kind)
                  (plist-get argument :keyword)
                  (plist-get argument :default)
                  (plist-get argument :default-p)))
          (nth 2 task)))

;;; Reading a Maak file

(ert-deftest maak-test-grammar-task-names ()
  "Only exported, top-level procedures are tasks, in file order."
  (let ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm"))))
    (should (equal (mapcar #'car tasks)
                   '("no-args" "required-only" "optional-args"
                     "optional-defaults" "keyword-args" "dotted-rest"
                     "keyword-rest" "mixed" "build-all!" "lambda-task"
                     "lambda-star-task")))
    (should-not (assoc "hidden-helper" tasks))
    (should-not (assoc "commented-out" tasks))
    (should-not (assoc "block-commented" tasks))
    (should-not (assoc "datum-commented" tasks))
    (should-not (assoc "note" tasks))))

(ert-deftest maak-test-required-arguments ()
  "Required arguments are read in order, with no marker leaking through."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm")))
         (task (assoc "required-only" tasks)))
    (should (equal (nth 1 task) "Take two required arguments."))
    (should (equal (maak-test-arguments task)
                   '(("first" required nil nil nil)
                     ("second" required nil nil nil))))))

(ert-deftest maak-test-optional-arguments ()
  "An optional argument is optional with or without a default."
  (let ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm"))))
    (should (equal (maak-test-arguments (assoc "optional-args" tasks))
                   '(("required" required nil nil nil)
                     ("maybe" optional nil nil nil))))
    (should (equal (maak-test-arguments (assoc "optional-defaults" tasks))
                   '(("required" required nil nil nil)
                     ("first" optional nil "\"one\"" t)
                     ("second" optional nil "\"two\"" t))))))

(ert-deftest maak-test-keyword-arguments ()
  "Keyword arguments keep their keyword and default; flags are not arguments."
  (let ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm"))))
    (should (equal (maak-test-arguments (assoc "keyword-args" tasks))
                   '(("required" required nil nil nil)
                     ("flag" key "#:flag" "#t" t)
                     ("count" key "#:count" "2" t))))))

(ert-deftest maak-test-rest-arguments ()
  "Both spellings of a rest argument are read as one rest argument."
  (let ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm"))))
    (should (equal (maak-test-arguments (assoc "dotted-rest" tasks))
                   '(("first" required nil nil nil)
                     ("rest" rest nil nil nil))))
    (should (equal (maak-test-arguments (assoc "keyword-rest" tasks))
                   '(("first" required nil nil nil)
                     ("rest" rest nil nil nil))))))

(ert-deftest maak-test-mixed-arguments ()
  "Every kind of argument can appear in one signature."
  (let ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm"))))
    (should (equal (maak-test-arguments (assoc "mixed" tasks))
                   '(("required" required nil nil nil)
                     ("maybe" optional nil "\"m\"" t)
                     ("flag" key "#:flag" "\"f\"" t)
                     ("rest" rest nil nil nil))))))

(ert-deftest maak-test-lambda-task ()
  "A task bound to a lambda value is a task."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm")))
         (task (assoc "lambda-task" tasks)))
    (should task)
    (should (equal (nth 1 task)
                   "Take two required arguments, defined as a lambda value."))
    (should (equal (maak-test-arguments task)
                   '(("first" required nil nil nil)
                     ("second" required nil nil nil))))))

(ert-deftest maak-test-lambda-star-task ()
  "A task bound to a lambda* value keeps its optional argument."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm")))
         (task (assoc "lambda-star-task" tasks)))
    (should task)
    (should (equal (maak-test-arguments task)
                   '(("required" required nil nil nil)
                     ("opt" optional nil "1" t))))))

(ert-deftest maak-test-punctuated-task-name ()
  "A task name may contain punctuation, and a false default is kept as text."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "grammar.scm")))
         (task (assoc "build-all!" tasks)))
    (should task)
    (should (equal (maak-test-arguments task)
                   '(("fast?" optional nil "#f" t))))))

(ert-deftest maak-test-open-season ()
  "Without an export list every top-level procedure is a task."
  (let ((tasks (maak-get-tasks (maak-test-fixture "open.scm"))))
    (should (equal (mapcar #'car tasks)
                   '("alpha" "undocumented" "outer" "documented"
                     "commented-signature" "datum-commented" "escaped-quote"
                     "redefined")))
    (should-not (assoc "inner" tasks))
    (should-not (assoc "not-a-procedure" tasks))))

(ert-deftest maak-test-nested-define-is-not-a-task ()
  "A helper defined inside a task body belongs to the body."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "open.scm")))
         (outer (assoc "outer" tasks)))
    (should outer)
    (should-not (assoc "inner" tasks))))

(ert-deftest maak-test-empty-export-list-is-open ()
  "An empty export list means open season, exactly as in maak."
  (should (equal (mapcar #'car
                         (maak-get-tasks (maak-test-fixture "empty-exports.scm")))
                 '("alpha"))))

(ert-deftest maak-test-docstrings ()
  "A docstring is the first string of the body, and absent means empty."
  (let* ((open (maak-get-tasks (maak-test-fixture "open.scm")))
         (documented (assoc "documented" open))
         (escaped (assoc "escaped-quote" open))
         (commented (assoc "commented-signature" open)))
    (should (equal (nth 1 documented) "First line.\nSecond line."))
    (should (equal (nth 1 escaped)
                   "A docstring with a \"quoted\" word."))
    ;; A task without a docstring has none, rather than borrowing the first
    ;; string of some later task.
    (should (equal (nth 1 (assoc "undocumented" open)) ""))
    ;; The fixture's `commented-signature' has a docstring too; this checks the
    ;; block comment did not swallow the arguments after it.
    (should (equal (maak-test-arguments commented)
                   '(("maybe" optional nil "1" t))))
    (should (equal (nth 1 (assoc "no-args"
                                 (maak-get-tasks
                                  (maak-test-fixture "grammar.scm"))))
                   "Take no arguments at all."))))

(ert-deftest maak-test-comment-in-signature ()
  "A datum comment in an argument list comments out one datum only."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "open.scm")))
         (task (assoc "datum-commented" tasks)))
    (should (equal (maak-test-arguments task)
                   '(("value" optional nil "2" t))))))

(ert-deftest maak-test-redefinition-keeps-the-last ()
  "A name defined twice is one task, and the last definition is the one maak sees."
  (let* ((tasks (maak-get-tasks (maak-test-fixture "open.scm")))
         (named (seq-filter (lambda (task) (equal (car task) "redefined"))
                            tasks)))
    (should (= (length named) 1))
    (should (equal (nth 1 (car named)) "The last definition wins."))))

(ert-deftest maak-test-exports-from-module ()
  "The export list is read from the module form, past comments and other keys."
  (maak-test-with-scheme-buffer
   "(define-module (maak)
  #:declarative? #t
  ;; #:export (not-this)
  #:use-module (ice-9 format)
  #:re-export (log-info)
  #:export (build
            test))
"
   (should (equal (maak-get-exports) '("build" "test")))))

(ert-deftest maak-test-no-module-has-no-exports ()
  "A file without a module form has no export list, so everything is a task."
  (maak-test-with-scheme-buffer
   "(define (alpha) \"A task.\" 'alpha)\n"
   (should-not (maak-get-exports))))

(ert-deftest maak-test-unbalanced-file-keeps-earlier-tasks ()
  "An unbalanced file still yields the tasks read before the mistake."
  (let ((file (make-temp-file "maak-test-unbalanced-" nil ".scm")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(define (alpha) \"A task.\" 'alpha)\n(define (broken\n"))
          (should (equal (mapcar #'car (maak-get-tasks file)) '("alpha"))))
      (delete-file file))))

;;; Completion

(ert-deftest maak-test-completion-is-sorted ()
  "The completion candidates are the task names, sorted."
  (maak-test-with-project
      "(define-module (maak)
  #:export (zebra alpha))

(define (zebra) \"Z.\" #t)
(define (alpha) \"A.\" #t)"
    (let (collection)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _)
                   (setq collection candidates)
                   "alpha"))
                ((symbol-function 'read-string)
                 (lambda (&rest _) (error "No prompt expected"))))
        (should (equal (maak-read-task) '("alpha" ())))
        (should (equal collection '("alpha" "zebra")))))))

(ert-deftest maak-test-annotation-shows-signature-and-doc ()
  "The annotation shows the command-line shape and the first docstring line."
  (let* ((tasks (list (list "deploy"
                            "Deploy the built site."
                            (list (maak-test-argument "target" 'required)
                                  (maak-test-argument "env" 'optional
                                                      nil "\"staging\"" t)))
                      (list "build" "Build it." nil)))
         (annotation (maak-make-annotation-function tasks))
         (deploy (funcall annotation "deploy"))
         (build (funcall annotation "build")))
    (should (string-match-p "target" deploy))
    (should (string-match-p "\\[env=\"staging\"\\]" deploy))
    (should (string-match-p "Deploy the built site\\." deploy))
    (should-not (string-match-p "#:optional" deploy))
    (should (equal (string-trim build) "Build it."))
    (should-not (funcall annotation "missing"))))

;;; Prompting for arguments

(ert-deftest maak-test-optional-blank-is-omitted ()
  "A blank optional argument is left out instead of becoming the empty string."
  (maak-test-with-project
      "(define-module (maak)
  #:export (deploy))

(define* (deploy target #:optional (env \"staging\"))
  \"Deploy TARGET.\"
  (list target env))"
    (maak-test-with-prompts "deploy" '("prod" "")
      (should (equal (maak-read-task) '("deploy" ("prod"))))
      (should (equal (nreverse maak-test-prompts)
                     '("Argument <target>: "
                       "Argument <env> [\"staging\"] (RET to omit): "))))))

(ert-deftest maak-test-optional-value-is-passed ()
  "A non-blank optional argument is passed as typed."
  (maak-test-with-project
      "(define-module (maak)
  #:export (deploy))

(define* (deploy target #:optional env)
  \"Deploy TARGET.\"
  (list target env))"
    (maak-test-with-prompts "deploy" '("prod" "production")
      (should (equal (maak-read-task) '("deploy" ("prod" "production"))))
      (should (equal (nreverse maak-test-prompts)
                     '("Argument <target>: "
                       "Argument <env> (optional, RET to omit): "))))))

(ert-deftest maak-test-omitted-optional-skips-later-arguments ()
  "Leaving out an optional argument also leaves out the ones after it."
  (maak-test-with-project
      "(define-module (maak)
  #:export (ship))

(define* (ship target #:optional (env \"staging\") (region \"eu\"))
  \"Ship TARGET.\"
  (list target env region))"
    (maak-test-with-prompts "ship" '("prod" "")
      (should (equal (maak-read-task) '("ship" ("prod"))))
      ;; The second optional was not asked for: its slot is not reachable
      ;; without a value for the first one.
      (should (= (length maak-test-prompts) 2)))))

(ert-deftest maak-test-required-argument-rejects-blank ()
  "A required argument that is left blank stops the run before maak starts."
  (maak-test-with-project
      "(define-module (maak)
  #:export (deploy))

(define (deploy target)
  \"Deploy TARGET.\"
  (list target))"
    (maak-test-with-prompts "deploy" '("")
      (should-error (maak-read-task) :type 'user-error))))

(ert-deftest maak-test-keyword-arguments-are-not-prompted ()
  "Keyword arguments cannot be passed by maak, so they are never asked for."
  (maak-test-with-project
      "(define-module (maak)
  #:export (kw))

(define* (kw required #:key (flag #t))
  \"Keyword arguments only ever come from defaults.\"
  (list required flag))"
    (maak-test-with-prompts "kw" '("value")
      (should (equal (maak-read-task) '("kw" ("value"))))
      (should (equal (nreverse maak-test-prompts)
                     '("Argument <required>: "))))))

(ert-deftest maak-test-required-keyword-argument-cannot-run ()
  "A keyword argument without a default cannot be passed, so it is reported."
  (maak-test-with-project
      "(define-module (maak)
  #:export (kw))

(define* (kw required #:key needed)
  \"A keyword argument with no default.\"
  (list required needed))"
    (maak-test-with-prompts "kw" '("value")
      (should-error (maak-read-task) :type 'user-error))))

(ert-deftest maak-test-rest-argument-splits-words ()
  "A rest argument takes any number of space separated words."
  (maak-test-with-project
      "(define-module (maak)
  #:export (echo))

(define (echo . words)
  \"Echo the words.\"
  words)"
    (maak-test-with-prompts "echo" '("one two  three")
      (should (equal (maak-read-task) '("echo" ("one" "two" "three"))))
      (should (equal (nreverse maak-test-prompts)
                     '("Arguments <words> (space separated, RET for none): "))))))

(ert-deftest maak-test-rest-argument-may-be-empty ()
  "A blank rest argument passes no words rather than one empty word."
  (maak-test-with-project
      "(define-module (maak)
  #:export (echo))

(define (echo . words)
  \"Echo the words.\"
  words)"
    (maak-test-with-prompts "echo" '("   ")
      (should (equal (maak-read-task) '("echo" ()))))))

(ert-deftest maak-test-argument-order ()
  "Required, optional and rest arguments are prompted in signature order."
  (maak-test-with-project
      "(define-module (maak)
  #:export (mixed))

(define* (mixed first #:optional (second 2) #:key (flag 3) #:rest rest)
  \"Every kind.\"
  (list first second flag rest))"
    (maak-test-with-prompts "mixed" '("a" "b" "c d")
      (should (equal (maak-read-task) '("mixed" ("a" "b" "c" "d"))))
      (should (equal (nreverse maak-test-prompts)
                     '("Argument <first>: "
                       "Argument <second> [2] (RET to omit): "
                       "Arguments <rest> (space separated, RET for none): "))))))

;;; Running a task

(ert-deftest maak-test-command-without-arguments ()
  "A task without arguments is named on its own."
  (should (equal (maak-command "build" nil) "maak build")))

(ert-deftest maak-test-command-quotes-arguments ()
  "Arguments are shell quoted one by one."
  (should (equal (maak-command "deploy" '("a b" "it's" "prod"))
                 (mapconcat #'shell-quote-argument
                            '("maak" "deploy" "a b" "it's" "prod")
                            " "))))

(ert-deftest maak-test-command-protects-dash-arguments ()
  "An argument that begins with a dash is set apart with `--'."
  (should (equal (maak-command "quick-math" '("-23" "42"))
                 (mapconcat #'shell-quote-argument
                            '("maak" "quick-math" "--" "-23" "42")
                            " ")))
  (should (equal (maak-command "build" '("-x"))
                 (mapconcat #'shell-quote-argument
                            '("maak" "build" "--" "-x")
                            " "))))

(ert-deftest maak-test-command-uses-custom-executable ()
  "`maak-executable' names the program that is run."
  (let ((maak-executable "/opt/maak/bin/maak"))
    (should (equal (maak-command "build" nil)
                   "/opt/maak/bin/maak build"))))

(ert-deftest maak-test-run-task-in-project-directory ()
  "A task runs in the directory of its maak.scm, with the arguments it was given."
  (maak-test-with-project
      "(define-module (maak)
  #:export (build))

(define (build) \"Build.\" #t)"
    (let (compiled directory)
      (cl-letf (((symbol-function 'compile)
                 (lambda (command &rest _)
                   (setq compiled command
                         directory default-directory)
                   nil)))
        (maak-run-task "build" '("with space"))
        (should (equal compiled (maak-command "build" '("with space"))))
        (should (equal directory maak-test-project-dir))))))

(ert-deftest maak-test-run-task-without-maak-file ()
  "A directory with no maak.scm is a user error, not a run somewhere else."
  (let* ((directory (file-name-as-directory
                     (make-temp-file "maak-test-empty-" t)))
         (default-directory directory))
    (unwind-protect
        (progn
          (should-not (maak-find-file))
          (should-error (maak-read-task) :type 'user-error)
          (should-error (maak-run-task "build" nil) :type 'user-error))
      (delete-directory directory t))))

(ert-deftest maak-test-find-file-walks-up ()
  "The nearest maak.scm is found from a subdirectory."
  (let* ((root (file-name-as-directory (make-temp-file "maak-test-find-" t)))
         (sub (expand-file-name "a/b" root))
         (file (expand-file-name "maak.scm" root)))
    (unwind-protect
        (progn
          (make-directory sub t)
          (with-temp-file file
            (insert "(define-module (maak)\n  #:declarative? #t)\n"))
          (let ((default-directory (file-name-as-directory sub)))
            (should (equal (maak-find-file) file))))
      (delete-directory root t))))

;;; This project's own Maak file

(ert-deftest maak-test-project-maak-file-is-wired ()
  "The repository's maak.scm is a Maak file with the tasks the project uses."
  (let* ((file (expand-file-name "maak.scm" maak-test-root))
         (tasks (maak-get-tasks file)))
    (should (equal (mapcar #'car tasks)
                   '("default" "test" "byte-compile" "ci"
                     "container-build" "container-run" "package-docker")))
    (dolist (name '("container-build" "container-run" "package-docker"))
      (should (equal (maak-test-arguments (assoc name tasks)) nil)))
    (should (equal (maak-test-arguments (assoc "default" tasks)) nil))
    (should (equal (maak-test-arguments (assoc "test" tasks))
                   '(("pattern" optional nil nil nil))))
    (should (equal (maak-test-arguments (assoc "ci" tasks)) nil))))

;;; Checking against maak and Guile
;;
;; The tests above say what the package should read.  These say that what it
;; reads is what the reference implementation reads, when those programs are
;; around; without them the tests are skipped rather than failing.

(defun maak-test-guile-arities (file names)
  "Ask Guile for the arity of each of NAMES, a list of task names, in FILE.

Returns an alist of (NAME REQUIRED OPTIONAL REST), where REST is 0 or 1.
Names Guile cannot answer for are left out."
  (let* ((script (format "\
(load %S)
(let ((module (resolve-module '(maak))))
  (for-each
   (lambda (name)
     (let* ((proc (module-ref module (string->symbol name)))
            (arity (and (procedure? proc)
                        (false-if-exception (procedure-minimum-arity proc)))))
       (if arity
           (format #t \"ARITY ~a ~a ~a ~a~%%\" name
                   (car arity) (cadr arity) (if (caddr arity) 1 0))
           (format #t \"UNKNOWN ~a~%%\" name))))
   (quote %S)))"
                   file names))
         (output (with-temp-buffer
                   (let ((status (call-process "guile" nil t nil "-c" script)))
                     (unless (equal status 0)
                       (ert-fail (format "guile failed: %s"
                                         (buffer-string))))
                     (buffer-string)))))
    (delq nil
          (mapcar (lambda (line)
                    (when (string-prefix-p "ARITY " line)
                      (let ((fields (split-string line " " t)))
                        (list (nth 1 fields)
                              (string-to-number (nth 2 fields))
                              (string-to-number (nth 3 fields))
                              (string-to-number (nth 4 fields))))))
                  (split-string output "\n" t)))))

(ert-deftest maak-test-guile-arity-parity ()
  "Required, optional and rest counts agree with Guile's own reader."
  (skip-unless (executable-find "guile"))
  (let* ((file (maak-test-fixture "grammar.scm"))
         (tasks (maak-get-tasks file))
         (arities (maak-test-guile-arities file (mapcar #'car tasks))))
    (skip-unless arities)
    (dolist (task tasks)
      (let* ((name (car task))
             (arguments (nth 2 task))
             (required (seq-count (lambda (argument)
                                    (eq (plist-get argument :kind) 'required))
                                  arguments))
             (optional (seq-count (lambda (argument)
                                    (eq (plist-get argument :kind) 'optional))
                                  arguments))
             (rest (if (seq-some (lambda (argument)
                                   (eq (plist-get argument :kind) 'rest))
                                 arguments)
                       1 0))
             (guile (cdr (assoc name arities))))
        (should guile)
        (unless (equal (list required optional rest) guile)
          (ert-fail
           (format "arity of %s: maak.el reads (%s required, %s optional, rest %s), Guile says %S"
                   name required optional rest guile)))))))

(ert-deftest maak-test-maak-listing-parity ()
  "The tasks maak.el finds are the tasks `maak --list' prints."
  (skip-unless (executable-find "maak"))
  (let* ((fixture (maak-test-fixture "grammar.scm"))
         (tasks (maak-get-tasks fixture))
         (output (with-temp-buffer
                   (let ((status (call-process "maak" nil t nil
                                               "-f" fixture "--list")))
                     (unless (equal status 0)
                       (ert-fail (format "maak --list failed: %s"
                                         (buffer-string))))
                     (buffer-string)))))
    (dolist (task tasks)
      (should (string-match-p (regexp-quote (car task)) output)))
    (should-not (string-match-p "hidden-helper" output))))

(provide 'maak-test)
;;; maak-test.el ends here
