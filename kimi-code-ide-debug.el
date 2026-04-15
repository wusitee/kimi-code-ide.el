;;; kimi-code-ide-debug.el --- Debug utilities for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, debug

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

;; Debug logging utilities for Kimi Code IDE.

;;; Code:

(defvar kimi-code-ide-debug nil
  "When non-nil, enable debug logging.")

(defvar kimi-code-ide-debug-buffer "*kimi-code-ide-debug*"
  "Buffer name for debug output.")

(defvar kimi-code-ide-log-with-context t
  "Include session context in log messages.")

(defun kimi-code-ide--debug-buffer ()
  "Get or create the debug buffer."
  (let ((buffer (get-buffer-create kimi-code-ide-debug-buffer)))
    (with-current-buffer buffer
      (unless (eq major-mode 'special-mode)
        (special-mode)))
    buffer))

(defun kimi-code-ide-debug (format-string &rest args)
  "Log a debug message using FORMAT-STRING and ARGS.
Only logs when `kimi-code-ide-debug' is non-nil."
  (when kimi-code-ide-debug
    (let ((buffer (kimi-code-ide--debug-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "[%s] %s\n"
                          (format-time-string "%Y-%m-%d %H:%M:%S.%3N")
                          (apply #'format format-string args)))))
      buffer)))

(defun kimi-code-ide-log (format-string &rest args)
  "Log a message using FORMAT-STRING and ARGS.
Message is displayed in the minibuffer and logged to debug buffer
when debug mode is enabled."
  (let ((message (apply #'format format-string args)))
    (message "Kimi Code: %s" message)
    (when kimi-code-ide-debug
      (apply #'kimi-code-ide-debug format-string args))))

(defun kimi-code-ide-show-debug ()
  "Show the debug buffer."
  (interactive)
  (pop-to-buffer (kimi-code-ide--debug-buffer)))

(defun kimi-code-ide-clear-debug ()
  "Clear the debug buffer."
  (interactive)
  (when-let ((buffer (get-buffer kimi-code-ide-debug-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))))

(provide 'kimi-code-ide-debug)

;;; kimi-code-ide-debug.el ends here
