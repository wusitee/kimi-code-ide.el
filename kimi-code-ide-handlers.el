;;; kimi-code-ide-handlers.el --- Tool handlers for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, tools

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file contains handlers for ACP client methods and diff viewing
;; for Kimi Code IDE.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ediff)
(require 'kimi-code-ide-debug)

(defvar ediff-control-buffer)
(defvar ediff-window-setup-function)
(defvar ediff-split-window-function)
(defvar ediff-control-buffer-suffix)

;;; Diff Management

(defvar kimi-code-ide-handlers--active-diffs (make-hash-table :test 'equal)
  "Hash table mapping tab names to diff info.")

(defun kimi-code-ide-handlers--create-diff-buffers (old-file-path new-file-contents tab-name)
  "Create buffers for diff comparison.
OLD-FILE-PATH is the path to the original file.
NEW-FILE-CONTENTS is the new content to diff against.
TAB-NAME is used for naming the new buffer.
Returns a cons cell (buffer-A . buffer-B)."
  (let ((file-exists (file-exists-p old-file-path))
        buffer-A buffer-B)
    (if file-exists
        (setq buffer-A (find-file-noselect old-file-path))
      (setq buffer-A (generate-new-buffer (format "*New file: %s*"
                                                  (file-name-nondirectory old-file-path))))
      (with-current-buffer buffer-A
        (setq buffer-file-name old-file-path)))
    (setq buffer-B (generate-new-buffer (format "*%s*" tab-name)))
    (with-current-buffer buffer-B
      (insert new-file-contents)
      (let ((mode (assoc-default old-file-path auto-mode-alist 'string-match)))
        (when mode
          (condition-case err
              (funcall mode)
            (error
             (kimi-code-ide-debug "Failed to activate %s for diff buffer: %s. Using fundamental-mode."
                                  mode (error-message-string err))
             (fundamental-mode))))))
    (cons buffer-A buffer-B)))

(defun kimi-code-ide-handlers-open-diff (old-file-path new-file-contents tab-name)
  "Open a diff view using ediff.
OLD-FILE-PATH is the original file path.
NEW-FILE-CONTENTS is the new content.
TAB-NAME is the name for the diff tab."
  (unless (and old-file-path new-file-contents tab-name)
    (signal 'error '("Missing required parameters for openDiff")))
  ;; Clean up existing diff with same tab name
  (when-let ((existing-diff (gethash tab-name kimi-code-ide-handlers--active-diffs)))
    (kimi-code-ide-handlers--cleanup-diff tab-name))
  (let* ((saved-winconf (current-window-configuration))
         (buffers (kimi-code-ide-handlers--create-diff-buffers
                   old-file-path new-file-contents tab-name))
         (buffer-A (car buffers))
         (buffer-B (cdr buffers))
         (file-exists (file-exists-p old-file-path)))
    (puthash tab-name
             `((buffer-A . ,buffer-A)
               (buffer-B . ,buffer-B)
               (old-file-path . ,old-file-path)
               (file-exists . ,file-exists)
               (saved-winconf . ,saved-winconf)
               (created-at . ,(current-time)))
             kimi-code-ide-handlers--active-diffs)
    (condition-case err
        (progn
          (dolist (window (window-list))
            (when (window-parameter window 'window-side)
              (delete-window window)))
          (let ((old-setup-fn ediff-window-setup-function)
                (old-split-fn ediff-split-window-function)
                (ediff-control-buffer-suffix (format "<%s>" tab-name)))
            (unwind-protect
                (progn
                  (setq ediff-window-setup-function 'ediff-setup-windows-plain
                        ediff-split-window-function 'split-window-horizontally)
                  (ediff-buffers buffer-A buffer-B))
              (setq ediff-window-setup-function old-setup-fn
                    ediff-split-window-function old-split-fn))))
      (error
       (when buffer-B
         (kill-buffer buffer-B))
       (remhash tab-name kimi-code-ide-handlers--active-diffs)
       (signal (car err) (cdr err))))
    `((status . "opened")
      (tab-name . ,tab-name))))

(defun kimi-code-ide-handlers--cleanup-diff (tab-name)
  "Clean up diff session for TAB-NAME."
  (when-let ((diff-info (gethash tab-name kimi-code-ide-handlers--active-diffs)))
    (let ((buffer-A (alist-get 'buffer-A diff-info))
          (buffer-B (alist-get 'buffer-B diff-info))
          (file-exists (alist-get 'file-exists diff-info)))
      (when (and buffer-B (buffer-live-p buffer-B))
        (kill-buffer buffer-B))
      (when (and buffer-A (buffer-live-p buffer-A) (not file-exists))
        (kill-buffer buffer-A))
      (remhash tab-name kimi-code-ide-handlers--active-diffs))))

(defun kimi-code-ide-handlers-close-all-diff-tabs ()
  "Close all diff tabs."
  (let ((closed-count 0))
    (maphash (lambda (tab-name _diff-info)
               (kimi-code-ide-handlers--cleanup-diff tab-name)
               (setq closed-count (1+ closed-count)))
             kimi-code-ide-handlers--active-diffs)
    (format "CLOSED_%d_DIFF_TABS" closed-count)))

(provide 'kimi-code-ide-handlers)

;;; kimi-code-ide-handlers.el ends here
