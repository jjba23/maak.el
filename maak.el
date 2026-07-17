;;; maak.el --- Maak integration for Emacs -*- lexical-binding: t -*-

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; Version: 0.8.1
;; Author: Josep Bigorra <jjbigorra@gmail.com>
;; Maintainer: Josep Bigorra <jjbigorra@gmail.com>
;; URL: https://codeberg.org/jjba23/maak.el
;; Keywords: faces
;; Package: maak.el
;; Package-Requires: ((emacs "28.1"))

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Maak integration for Emacs.
;; See https://codeberg.org/jjba23/maak for more info on Maak.

;;; Code:

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

(defun maak-get-exports ()
  "Extract the list of exported task names as strings from the current buffer.
Returns nil if no #:export directive is found or if it is empty."
  (save-excursion
    (goto-char (point-min))
    (let (found exports-list)
      ;; Search for "#:export", ensuring we aren't in a string or comment
      (while (and (not found) (search-forward "#:export" nil t))
        (let ((state (syntax-ppss)))
          (unless (or (nth 3 state) (nth 4 state)) ; 3 is string, 4 is comment
            (setq found t)
            (forward-comment (point-max))
            ;; If the next character is an open paren, parse the export list
            (when (eq (char-after) ?\()
              (condition-case nil
                  (let ((exports (read (current-buffer))))
                    (when (listp exports)
                      (setq exports-list (mapcar #'symbol-name exports))))
                (error nil))))))
      exports-list)))

(defun maak-find-file ()
  "Find the maak.scm file in the current directory or its parents."
  (let ((dir (locate-dominating-file default-directory "maak.scm")))
    (when dir
      (expand-file-name "maak.scm" dir))))

(defun maak-get-tasks (file)
  "Extract task names, arguments, and docstrings from the given maak.scm FILE.
Returns a list of elements: (task-name docstring argument-list), respecting
the #:export visibility rules."
  (let (tasks)
    (with-temp-buffer
      (emacs-lisp-mode) ; Activates standard Lisp syntax table for accurate parsing
      (insert-file-contents file)
      (let ((exports (maak-get-exports)))
        (goto-char (point-min))
        (while (re-search-forward "^[[:space:]]*([[:space:]]*define[[:space:]]+(\\([a-zA-Z0-9_---+*/<>=!?]+\\)" nil t)
          (let ((task (match-string 1))
                (docstring "")
                (args nil))
            (save-excursion
              (goto-char (match-beginning 1))
              (backward-char 1)                     ; Move to the opening '(' of the signature
              (condition-case nil
                  (progn
                    (forward-sexp 1)                ; Move past the signature: (task-name arg1 ...)
                    (let ((sig-end (point)))
                      (save-excursion
                        (goto-char (match-end 1))   ; Jump right past the task name inside signature
                        (let ((args-str (buffer-substring-no-properties (point) (1- sig-end))))
                          ;; Split by whitespace to extract argument names
                          (setq args (split-string args-str "[[:space:]\n\r]+" t)))))
                    ;; Move forward to capture optional docstring string literal
                    (forward-comment (point-max))
                    (when (eq (char-after) ?\")
                      (let ((start (point)))
                        (forward-sexp 1)
                        (setq docstring (buffer-substring-no-properties (1+ start) (1- (point)))))))
                (error nil)))
            (push (list task docstring args) tasks)))

        ;; Apply Task Export & Visibility rules
        (let ((all-tasks (nreverse tasks)))
          (if exports
              (seq-filter (lambda (task-info)
                            (member (car task-info) exports))
                          all-tasks)
            all-tasks))))))

(defun maak-make-annotation-function (tasks)
  "Return an annotation function formatted dynamically for TASKS columns."
  (let* ((max-task-len (seq-max (mapcar (lambda (cell) (length (car cell))) tasks)))
         (args-align (+ max-task-len 2))
         ;; Compute width for the third column alignment (Task Name + Arguments)
         (max-total-len (seq-max (mapcar (lambda (cell)
                                           (let ((args (nth 2 cell)))
                                             (+ max-task-len
                                                (if args
                                                    (+ 2 (length (string-join args " ")))
                                                  0))))
                                         tasks)))
         (doc-align (+ max-total-len maak-annotation-padding)))
    (lambda (cand)
      (let* ((meta (assoc cand tasks))
             (doc (nth 1 meta))
             (args (nth 2 meta))
             (args-str (if args (string-join args " ") ""))
             (summary (if (and doc (not (string= doc "")))
                          (car (split-string doc "\n"))
                        "")))
        (concat
         (if args
             (concat (propertize " " 'display `(space :align-to ,args-align))
                     (propertize args-str 'face 'maak-task-arguments-face))
           "")
         (if (not (string= summary ""))
             (concat (propertize " " 'display `(space :align-to ,doc-align))
                     (propertize summary 'face 'maak-task-documentation-face))
           ""))))))

(defun maak-read-task ()
  "Prompt the user to select a task and dynamically input arguments.
Returns a list of the format: (task-name (arg-value1 arg-value2 ...))"
  (let ((file (maak-find-file)))
    (unless file
      (user-error "No maak.scm found in this directory or its parents"))
    (let ((tasks (maak-get-tasks file)))
      (unless tasks
        (user-error "No runnable tasks found in %s" file))
      (let* ((completion-extra-properties
              `(:annotation-function ,(maak-make-annotation-function tasks)))
             (task-name (completing-read "Run maak task: " tasks nil t))
             (meta (assoc task-name tasks))
             (args-meta (nth 2 meta))
             (arg-vals nil))
        ;; Loop and prompt sequentially for each defined task argument
        (dolist (arg args-meta)
          (push (read-string (format "Argument <%s>: " arg)) arg-vals))
        (list task-name (nreverse arg-vals))))))

;;;###autoload
(defun maak-run-task (task args)
  "Select and run a TASK with ARGS from the local maak.scm file."
  (interactive (maak-read-task))
  (let* ((file (maak-find-file))
         (dir (file-name-directory file)))
    (let ((default-directory dir))
      ;; Build safely escaped command list, executing: maak <task> <arg1> <arg2>...
      (let ((command (mapconcat #'shell-quote-argument (cons "maak" (cons task args)) " ")))
        (compile command)))))

(provide 'maak.el)

;;; maak.el ends here
