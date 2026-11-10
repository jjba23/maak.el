;;; maak.el --- Maak integration for Emacs -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Version: 0.10.3
;; Author: Josep Bigorra <jjbigorra@gmail.com>
;; Maintainer: Josep Bigorra <jjbigorra@gmail.com>
;; URL: https://github.com/jjba23/maak.el
;; Keywords: tools
;; Package: maak.el
;; Package-Requires: ((emacs "28.1"))

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Maak integration for Emacs.
;; See https://github.com/jjba23/maak for more info on Maak.
;;
;; A Maak file is a Guile module: every top-level procedure it defines can be a
;; task, and an `#:export' list decides which ones are.  This package reads that
;; file the way maak does, so the completion menu shows the tasks a run could
;; name, with the arguments they take.
;;
;; The argument lists are Guile lambda lists, and every form Guile accepts is
;; understood:
;;
;;   (define (build target) ...)                      ; required arguments
;;   (define* (deploy target #:optional (env "dev")) ...) ; optional, with default
;;   (define* (run #:key (jobs 1) #:allow-other-keys) ...) ; keyword arguments
;;   (define (echo . words) ...)                      ; a dotted rest argument
;;   (define* (echo #:rest words) ...)                ; the same, spelled out
;;   (define report (lambda (day) ...))               ; a lambda value
;;
;; Two consequences shape the prompts.  A keyword argument cannot be passed by
;; maak's command line, which only ever passes positional strings, so a keyword
;; argument is never asked for: its default is what the task will see.  And an
;; optional argument that is answered with an empty line is left out of the
;; command entirely, so the task's own default applies instead of the empty
;; string.  Leaving an optional argument out also leaves out every argument
;; after it, because maak binds positional words in order.
;;
;; `maak-get-tasks' returns one entry per task, shaped as
;;
;;   (TASK-NAME DOCSTRING ARGUMENTS)
;;
;; where each element of ARGUMENTS is a plist with `:name', `:kind' (one of
;; `required', `optional', `key' or `rest'), and, for an argument that has one,
;; `:default' (the default expression as it is written in the file) plus
;; `:default-p'.  A keyword argument also has `:keyword'.

;;; Code:

(require 'compile)
(require 'seq)
(require 'subr-x)
;; `maak-goto-task' puts the point it came from on the marker stack, and
;; `xref-push-marker-stack' is not autoloaded on every Emacs this package
;; supports, so the library that holds it is loaded here.
(require 'xref)

(defgroup maak nil
  "Customizations for the maak task runner."
  :group 'tools)

(defface maak-task-arguments-face
  '((t :inherit font-lock-variable-name-face :italic t))
  "Face used to render task arguments in the minibuffer."
  :group 'maak)

(defface maak-task-documentation-face
  '((t :inherit font-lock-doc-face))
  "Face used to render task docstring annotations in the minibuffer."
  :group 'maak)

(defcustom maak-annotation-padding 4
  "Number of spaces to maintain between columns in the completion view."
  :type 'integer
  :group 'maak)

(defcustom maak-executable "maak"
  "Name of, or path to, the maak executable."
  :type 'string
  :group 'maak)

;;; Reading Scheme
;;
;; The file is read structurally, with the syntax table doing the work of
;; strings, line comments, `#|...|#' block comments and `#;' datum comments.
;; Nothing is evaluated and no reader is relied on: Guile's reader accepts
;; syntax -- `#:optional', `#|...|#', `#;datum' -- that the Emacs Lisp reader
;; does not, and the `#:' of a keyword argument would be lost if it were read
;; as Lisp.

(defconst maak--section-markers
  '(("#:optional" . optional)
    ("#:key" . key)
    ("#:rest" . rest))
  "The lambda-list keywords that start an argument section.")

(defun maak--scheme-mode ()
  "Put the current buffer in `scheme-mode' without running its hooks.

The syntax propertization is done here rather than left to font locking:
without it, a `#;' datum comment is not yet a comment as far as
`forward-sexp' is concerned, and a signature that contains one does not scan."
  (delay-mode-hooks (scheme-mode))
  (syntax-propertize (point-max)))

(defun maak--skip-space-and-comments ()
  "Move past whitespace and comments, including `#;' datum comments.

`forward-comment' handles whitespace, `;' comments and `#|...|#' block
comments in `scheme-mode'.  It does not skip a leading `#;', though, while
`forward-sexp' treats the commented datum as part of the following sexp, so
that one is skipped here, before anything else looks at the buffer."
  (let (again)
    (while (progn
             (forward-comment (point-max))
             (setq again nil)
             (when (looking-at "#;")
               (forward-char 2)
               (maak--skip-space-and-comments)
               (when (< (point) (point-max))
                 (forward-sexp 1))
               (setq again t))
             again))))

(defun maak--text (start end)
  "Return the buffer text between START and END, with surrounding space removed."
  (string-trim (buffer-substring-no-properties start end)))

(defun maak--collapse-whitespace (text)
  "Return TEXT with every run of whitespace turned into one space."
  (string-trim (replace-regexp-in-string "[ \t\n\r\f]+" " " text)))

(defun maak--top-level-forms ()
  "Return the (START . END) bounds of each top-level form in the buffer.

A form that cannot be scanned ends the walk rather than raising: a Maak file
being edited is allowed to be unbalanced, and the tasks before the mistake are
still worth showing."
  (save-excursion
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while (progn
                   (maak--skip-space-and-comments)
                   (< (point) (point-max)))
            (let ((start (point)))
              (forward-sexp 1)
              (when (> (point) start)
                (push (cons start (point)) forms))))
        (error nil))
      (nreverse forms))))

(defun maak--list-items (start end)
  "Return the (START . END) bounds of each element of the list START..END.

START is the position of the opening parenthesis and END the position just
after the closing one.  Elements are returned in order, and a dotted tail is
returned as its two elements -- the dot and the name -- so a signature can be
read without special casing."
  (save-excursion
    (goto-char (1+ start))
    (let (items)
      (condition-case nil
          (while (progn
                   (maak--skip-space-and-comments)
                   (< (point) (1- end)))
            (let ((item-start (point)))
              (forward-sexp 1)
              (when (> (point) item-start)
                (push (cons item-start (point)) items))))
        (error nil))
      (nreverse items))))

(defun maak--item-text (item)
  "Return the text of the list ITEM, a (START . END) pair, as a string."
  (and item (maak--text (car item) (cdr item))))

(defun maak--parse-argument (item kind)
  "Return a plist describing the argument ITEM, read as KIND.

ITEM is a `(START . END)' pair.  A bare name is an argument without a default.
A list is a specification: `(name default)', and for a keyword argument also
`((#:keyword name) default)'.  The default is kept as the source text that
follows the name, so `3', `\"dev\"' and `(list 1 2)' all read back the way they
were written."
  (let* ((start (car item))
         (end (cdr item))
         (parenthesized (and (< start end) (eq (char-after start) ?\()))
         (pieces (if parenthesized (maak--list-items start end) (list item)))
         (head (car pieces))
         (name (maak--item-text head))
         (keyword nil)
         (default nil)
         (default-p nil))
    ;; A keyword argument may name its keyword and its variable separately:
    ;; `((#:count number) 1)'.  Both spellings are read here.
    (when (and name (string-prefix-p "(" name))
      (let* ((inner (maak--list-items (car head) (cdr head)))
             (names (mapcar #'maak--item-text inner)))
        (cond
         ((>= (length names) 2)
          (setq keyword (nth 0 names)
                name (nth 1 names)))
         ((= (length names) 1)
          (setq name (nth 0 names))))))
    (when parenthesized
      (let ((rest (cdr pieces)))
        (when rest
          (setq default-p t
                default (maak--collapse-whitespace
                         (buffer-substring-no-properties
                          (caar rest)
                          (cdr (car (last rest)))))))))
    (when (and (eq kind 'key) name (null keyword))
      (setq keyword (concat "#:" name)))
    (list :name name :kind kind :keyword keyword
          :default default :default-p default-p)))

(defun maak--parse-arguments (items)
  "Return the argument plists described by the parameter list ITEMS.

`#:optional' starts the optional arguments, `#:key' the keyword arguments and
`#:rest' the rest argument; a dotted tail is a rest argument too.
`#:allow-other-keys' is a flag rather than an argument and is dropped."
  (let ((section 'required)
        (rest-next nil)
        (arguments nil))
    (dolist (item items)
      (let ((text (maak--item-text item)))
        (cond
         ((assoc text maak--section-markers)
          (setq section (cdr (assoc text maak--section-markers))))
         ((string= text ".")
          (setq rest-next t))
         ;; `#:allow-other-keys' and any other marker are flags, not names.
         ((and text (string-prefix-p "#:" text))
          nil)
         ((null text)
          nil)
         (t
          (let ((kind (if rest-next 'rest section)))
            (push (maak--parse-argument item kind) arguments)
            (setq rest-next nil))))))
    (nreverse arguments)))

(defun maak--parse-signature (start end)
  "Return (NAME . ARGUMENTS) for the signature list at START..END."
  (let* ((items (maak--list-items start end))
         (name (maak--item-text (car items))))
    ;; A curried definition `(define ((f a) b) ...)' is a procedure, but its
    ;; signature is not one a command line can describe, so it is not a task.
    (when (and name (string-prefix-p "(" name))
      (setq name nil))
    (cons name (maak--parse-arguments (cdr items)))))

(defun maak--docstring-after (start end)
  "Return the docstring literal starting at or after START, or nil.

Guile's docstring is the first expression of a task's body when it is a
string, so nothing is searched beyond that first expression.  END bounds the
definition."
  (save-excursion
    (goto-char start)
    (maak--skip-space-and-comments)
    (when (and (< (point) end) (eq (char-after) ?\"))
      (let ((string-start (point)))
        (forward-sexp 1)
        (let ((raw (buffer-substring-no-properties string-start (point))))
          (condition-case nil
              (car (read-from-string raw))
            (error nil)))))))

(defun maak--parse-definition (start end)
  "Return (NAME DOCSTRING ARGUMENTS START) for the definition at START..END.

Only a procedure definition is a task, spelled either as shorthand
`(define (name arg ...) body)' -- or `define*' -- or as a value bound to a
`lambda' or `lambda*' form.  A value definition, such as
`(define build-dir \"build\")', defines no task and returns nil.  START is
carried along so a task can be visited where it is written."
  (let ((items (maak--list-items start end)))
    (when items
      (let* ((head (maak--item-text (car items)))
             (parts (cdr items)))
        (when (member head '("define" "define*"))
          (let* ((first (car parts))
                 (second (nth 1 parts))
                 (name nil)
                 (arguments nil)
                 (body-start nil))
            (cond
             ;; (define (name arg ...) body ...)
             ((and first (eq (char-after (car first)) ?\())
              (let ((parsed (maak--parse-signature (car first) (cdr first))))
                (setq name (car parsed)
                      arguments (cdr parsed)
                      body-start (cdr first))))
             ;; (define name (lambda (arg ...) body ...))
             ((and first second (eq (char-after (car second)) ?\()
                   (not (eq (char-after (car first)) ?\()))
              (let* ((lambda-items (maak--list-items (car second) (cdr second)))
                     (lambda-head (maak--item-text (car lambda-items)))
                     (lambda-list (nth 1 lambda-items)))
                (when (and (member lambda-head '("lambda" "lambda*"))
                           lambda-list
                           (eq (char-after (car lambda-list)) ?\())
                  (setq name (maak--item-text first)
                        arguments (maak--parse-arguments
                                   (maak--list-items (car lambda-list)
                                                     (cdr lambda-list)))
                        ;; The docstring, if any, is the first body form of
                        ;; the lambda, so the body starts at its lambda list.
                        body-start (cdr lambda-list))))))
            (when (and name body-start)
              (list name
                    (or (maak--docstring-after body-start end) "")
                    arguments
                    start))))))))

(defun maak--export-clause (items)
  "Return the item that holds the export list in the module clauses ITEMS."
  (let (found)
    (while (and items (not found))
      (if (string= (maak--item-text (car items)) "#:export")
          (setq found (nth 1 items))
        (setq items (cdr items))))
    found))

(defun maak--exports-of-item (export-item)
  "Return the names exported by the list item EXPORT-ITEM, or nil."
  (when (and export-item
             (eq (char-after (car export-item)) ?\())
    (delq nil
          (mapcar #'maak--item-text
                  (maak--list-items (car export-item)
                                    (cdr export-item))))))

(defun maak-get-exports ()
  "Extract the exported task names as strings from the current buffer.

Returns nil when the file has no `define-module' export list, and also when
the export list is empty: both mean maak treats every procedure of the file as
a task.  The buffer should be in `scheme-mode', which is what gives the
scanner its comments and strings."
  (save-excursion
    (let ((exports nil))
      (dolist (bounds (maak--top-level-forms) exports)
        (let* ((items (maak--list-items (car bounds) (cdr bounds)))
               (head (maak--item-text (car items))))
          (when (and (string= head "define-module")
                     (not exports))
            (setq exports
                  (maak--exports-of-item
                   (maak--export-clause (cdr items))))))))))

(defun maak-find-file ()
  "Find the maak.scm file in the current directory or its parents."
  (let ((dir (locate-dominating-file default-directory "maak.scm")))
    (when dir
      (expand-file-name "maak.scm" dir))))

(defun maak-get-tasks (file)
  "Extract task names, arguments, docstrings and positions from the FILE.

Returns a list of (TASK-NAME DOCSTRING ARGUMENTS POSITION), respecting the
`#:export' visibility rules.  Only top-level procedure definitions are tasks:
a helper defined inside a task body belongs to that body, and a value
definition is not a procedure at all.  When a name is defined more than once,
the last definition is the one maak binds.  POSITION is where the definition
starts in FILE, which is what `maak-goto-task' visits."
  (with-temp-buffer
    (insert-file-contents file)
    (maak--scheme-mode)
    (let ((exports (maak-get-exports))
          (tasks nil))
      (dolist (bounds (maak--top-level-forms))
        (let ((task (maak--parse-definition (car bounds) (cdr bounds))))
          (when task
            (push task tasks))))
      (setq tasks (nreverse tasks))
      ;; `seq-uniq' keeps the first of equal elements, so read backwards to
      ;; keep the last definition of a name, then put the file order back.
      (setq tasks (reverse (seq-uniq (reverse tasks)
                                     (lambda (a b) (equal (car a) (car b))))))
      (if exports
          (seq-filter (lambda (task) (member (car task) exports)) tasks)
        tasks))))

(defun maak-argument-display (argument)
  "Return the command-line spelling of ARGUMENT.

A required argument is its name, an optional one is bracketed, a keyword one
keeps its `#:' and a rest argument is prefixed with `...'.  A default is shown
after `=' because it is what the task sees when the argument is left out."
  (let ((name (plist-get argument :name))
        (default (plist-get argument :default))
        (default-p (plist-get argument :default-p)))
    (pcase (plist-get argument :kind)
      ('required name)
      ('optional (if default-p
                     (format "[%s=%s]" name default)
                   (format "[%s]" name)))
      ('key (let ((keyword (or (plist-get argument :keyword)
                               (concat "#:" name))))
              (if default-p
                  (format "%s=%s" keyword default)
                keyword)))
      ('rest (format "...%s" name))
      (_ name))))

(defun maak-task-signature (arguments)
  "Return the command-line signature of ARGUMENTS as one string."
  (string-join (mapcar #'maak-argument-display arguments) " "))

(defun maak--argument-summary (argument)
  "Return one line describing ARGUMENT, for `maak-task-description'."
  (let ((name (plist-get argument :name))
        (kind (plist-get argument :kind))
        (default (plist-get argument :default))
        (default-p (plist-get argument :default-p)))
    (format "  %-14s %-9s %s"
            (or (plist-get argument :keyword) name)
            kind
            (cond ((and (eq kind 'key) (not default-p))
                   "maak cannot pass this one: give it a default")
                  (default-p (format "default: %s" default))
                  ((eq kind 'required) "a value is required")
                  ((eq kind 'rest) "any number of words, space separated")
                  (t "left out when the answer is blank")))))

(defun maak-task-description (task)
  "Return a plain-text description of TASK, an entry from `maak-get-tasks'.

The name comes first, then the whole docstring, then the command line the task
would run as and one line per argument.  The completion list has room for the
first line of a docstring beside the signature; this is where the rest goes."
  (let* ((name (nth 0 task))
         (doc (nth 1 task))
         (arguments (nth 2 task))
         (command (string-trim (concat maak-executable " " name " "
                                       (maak-task-signature arguments)))))
    (concat
     name "\n"
     (when (and doc (not (string-empty-p doc)))
       (concat "\n"
               (mapconcat (lambda (line) (concat "  " line))
                          (split-string doc "\n")
                          "\n")
               "\n"))
     "\nCommand: " command "\n"
     "\nArguments:"
     (if (null arguments)
         " none\n"
       (concat "\n"
               (mapconcat #'maak--argument-summary arguments "\n")
               "\n")))))

(defun maak-make-annotation-function (tasks)
  "Return an annotation function formatted dynamically for TASKS columns."
  (let* ((max-task-len (or (seq-max (mapcar (lambda (task)
                                              (length (car task)))
                                            tasks))
                           0))
         (max-sig-len (or (seq-max (mapcar (lambda (task)
                                            (length (maak-task-signature
                                                     (nth 2 task))))
                                          tasks))
                          0))
         (args-align (+ max-task-len 2))
         ;; Compute width for the third column alignment (Task Name + Arguments)
         (doc-align (+ max-task-len 2 max-sig-len maak-annotation-padding)))
    (lambda (candidate)
      (let ((task (assoc candidate tasks)))
        (when task
          (let* ((doc (nth 1 task))
                 (signature (maak-task-signature (nth 2 task)))
                 (summary (and doc (not (string-empty-p doc))
                               (car (split-string doc "\n")))))
            (concat
             (unless (string-empty-p signature)
               (concat (propertize " " 'display `(space :align-to ,args-align))
                       (propertize signature 'face 'maak-task-arguments-face)))
             (when summary
               (concat (propertize " " 'display `(space :align-to ,doc-align))
                       (propertize summary
                                   'face 'maak-task-documentation-face))))))))))

(defun maak--ask-for-argument (task argument)
  "Prompt for ARGUMENT of TASK and return the string the user typed.

A required argument must not be blank, because maak passes an empty word on
as the empty string and a task almost never means that.  An optional argument
may be left blank, which the caller reads as \"do not pass this one\"."
  (let ((name (plist-get argument :name))
        (kind (plist-get argument :kind))
        (default (plist-get argument :default))
        (default-p (plist-get argument :default-p)))
    (pcase kind
      ('required
       (let ((value (read-string (format "Argument <%s>: " name))))
         (when (string-empty-p (string-trim value))
           (user-error "Task %s needs a value for argument <%s>" task name))
         value))
      ('optional
       (read-string
        (if default-p
            (format "Argument <%s> [%s] (RET to omit): " name default)
          (format "Argument <%s> (optional, RET to omit): " name))))
      ('rest
       (read-string
        (format "Arguments <%s> (space separated, RET for none): " name)))
      (_ (read-string (format "Argument <%s>: " name))))))

(defun maak-read-arguments (task arguments)
  "Read the values to pass to TASK, described by ARGUMENTS.

Returns the words to put on the command line, in order.

An argument answered with a blank line is not passed at all, so a task's own
default is used instead of the empty string.  Once an optional argument is
left out, the arguments after it are left out too: maak binds positional
words in order, so a later word would otherwise fill the earlier slot.  A rest
argument takes any number of space separated words.  Keyword arguments are
never prompted for, because maak's command line passes positional strings and
a string is not a keyword; one without a default is an error, since there is
no way to supply it at all."
  ;; A keyword argument without a default cannot be supplied at all: maak's
  ;; command line passes strings, and a string never becomes a keyword.  The
  ;; run would fail inside Guile with "Missing keyword", which says nothing
  ;; about where the answer was supposed to come from, so it is said here.
  (dolist (argument arguments)
    (when (and (eq (plist-get argument :kind) 'key)
               (not (plist-get argument :default-p)))
      (user-error "Task %s needs keyword argument %s, which maak cannot pass; give it a default in the Maak file"
                  task
                  (or (plist-get argument :keyword)
                      (concat "#:" (plist-get argument :name))))))
  (let ((values nil)
        (stopped nil))
    (dolist (argument arguments)
      (pcase (plist-get argument :kind)
        ('key nil)
        ('required
         (push (maak--ask-for-argument task argument) values))
        ('optional
         (unless stopped
           (let ((value (maak--ask-for-argument task argument)))
             (if (string-empty-p (string-trim value))
                 (setq stopped t)
               (push value values)))))
        ('rest
         (unless stopped
           (let ((value (maak--ask-for-argument task argument)))
             (unless (string-empty-p (string-trim value))
               (dolist (word (split-string value "[ \t\n\r\f]+" t))
                 (push word values))))))))
    (when (and stopped (not noninteractive))
      (message "Leaving out the rest of the arguments of %s" task))
    (nreverse values)))

(defun maak-read-task-entry (&optional prompt)
  "Read a task from the nearest maak.scm and return its `maak-get-tasks' entry.

PROMPT defaults to \"maak task: \".  The completion list is annotated the way
`maak-run-task' annotates it, so the name, the arguments and the first line of
the docstring are what you choose from."
  (let ((file (maak-find-file)))
    (unless file
      (user-error "No maak.scm found in this directory or its parents"))
    (let ((tasks (maak-get-tasks file)))
      (unless tasks
        (user-error "No runnable tasks found in %s" file))
      (setq tasks (sort (copy-sequence tasks)
                        (lambda (a b) (string< (car a) (car b)))))
      (let* ((completion-extra-properties
              `(:annotation-function ,(maak-make-annotation-function tasks)))
             (task-name (completing-read (or prompt "maak task: ")
                                         (mapcar #'car tasks) nil t)))
        (assoc task-name tasks)))))

(defun maak-read-task ()
  "Prompt the user to select a task and dynamically input arguments.
Returns a list of the format: (task-name (arg-value1 arg-value2 ...))"
  (let ((task (maak-read-task-entry "Run maak task: ")))
    (list (nth 0 task)
          (maak-read-arguments (nth 0 task) (nth 2 task)))))

;;;###autoload
(defun maak-describe-task (task)
  "Describe TASK, an entry from `maak-get-tasks', in a help buffer.

The description holds the name, the whole docstring, the command line the task
would run as and one line per argument.  Returns the buffer, so a caller -- or
a test -- can read what was shown."
  (interactive (list (maak-read-task-entry "Describe maak task: ")))
  (let ((buffer (get-buffer-create (format "*maak task: %s*" (car task)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (maak-task-description task))
        (goto-char (point-min))
        (help-mode)))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun maak-goto-task (task)
  "Visit the definition of TASK, an entry from `maak-get-tasks'.

The Maak file opens at the definition, and the previous position goes on the
xref marker stack, so `xref-go-back' returns to it."
  (interactive (list (maak-read-task-entry "Go to maak task: ")))
  (let ((file (maak-find-file))
        (position (nth 3 task)))
    (unless file
      (user-error "No maak.scm found in this directory or its parents"))
    (unless position
      (user-error "%s carries no position; read the file with `maak-get-tasks'"
                  (nth 0 task)))
    (xref-push-marker-stack)
    (find-file file)
    ;; The file may have been edited since it was read, so the recorded
    ;; position is clamped rather than trusted to be inside the buffer.
    (goto-char (min position (point-max)))
    (recenter)))

(defun maak-command (task arguments)
  "Return the command line that runs TASK with ARGUMENTS.

The words are shell quoted one by one, so an argument keeps its spaces and
quotes.  An argument that begins with a dash is set apart with `--', which is
what keeps it from being read as an option of maak's own: the grammar of
`maak quick-math -- -23 42'.  The separator is only used when it is needed,
because an ordinary argument does not need it and an older maak does not know
it."
  (let ((words (append (list maak-executable task)
                       (when (seq-some (lambda (argument)
                                         (string-prefix-p "-" argument))
                                       arguments)
                         (list "--"))
                       arguments)))
    (mapconcat #'shell-quote-argument words " ")))

;;;###autoload
(defun maak-run-task (task arguments)
  "Run TASK with ARGUMENTS from the nearest maak.scm.

TASK is the name of a task and ARGUMENTS the list of words to pass to it.
The command runs in the directory that holds the maak.scm, so a task sees the
project it belongs to."
  (interactive (maak-read-task))
  (let ((file (maak-find-file)))
    (unless file
      (user-error "No maak.scm found in this directory or its parents"))
    (unless (executable-find maak-executable)
      (user-error "Cannot find the maak executable (%s); install maak or set `maak-executable'"
                  maak-executable))
    (let ((default-directory (file-name-directory file)))
      (compile (maak-command task arguments)))))

;; The conventional feature name is the file name without its extension; the
;; second one keeps `(require 'maak.el)', which this package shipped with,
;; working for configurations that already spell it that way.
(provide 'maak)
(provide 'maak.el)

;;; maak.el ends here
