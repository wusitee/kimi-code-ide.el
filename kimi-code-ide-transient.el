;;; kimi-code-ide-transient.el --- Transient menus for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, transient, menu

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

;; This file provides transient menus for Kimi Code IDE.

;;; Code:

(require 'transient)
(require 'kimi-code-ide-debug)

;; Declare functions from other files
(declare-function kimi-code-ide "kimi-code-ide" ())
(declare-function kimi-code-ide-stop "kimi-code-ide" ())
(declare-function kimi-code-ide-resume "kimi-code-ide" ())
(declare-function kimi-code-ide-list-sessions "kimi-code-ide" ())
(declare-function kimi-code-ide-switch-to-buffer "kimi-code-ide" ())
(declare-function kimi-code-ide-send-prompt "kimi-code-ide" (&optional prompt))
(declare-function kimi-code-ide-cancel-prompt "kimi-code-ide" ())
(declare-function kimi-code-ide-toggle "kimi-code-ide" ())
(declare-function kimi-code-ide-toggle-recent "kimi-code-ide" ())
(declare-function kimi-code-ide-acp--get-current-session "kimi-code-ide-acp" ())
(declare-function kimi-code-ide-acp-session-project-dir "kimi-code-ide-acp" (session))
(declare-function kimi-code-ide-acp-session-session-id "kimi-code-ide-acp" (session))
(declare-function kimi-code-ide--get-working-directory "kimi-code-ide" ())
(declare-function kimi-code-ide--ensure-cli "kimi-code-ide" ())

;; Declare variables
(defvar kimi-code-ide-cli-path)
(defvar kimi-code-ide-debug)
(defvar kimi-code-ide-window-side)
(defvar kimi-code-ide-window-width)
(defvar kimi-code-ide-window-height)
(defvar kimi-code-ide-focus-on-open)
(defvar kimi-code-ide-focus-kimi-after-ediff)
(defvar kimi-code-ide-show-kimi-window-in-ediff)
(defvar kimi-code-ide-use-ide-diff)
(defvar kimi-code-ide-switch-tab-on-ediff)
(defvar kimi-code-ide-use-side-window)
(defvar kimi-code-ide-cli-debug)
(defvar kimi-code-ide-cli-extra-flags)
(defvar kimi-code-ide-system-prompt)

;;; Helper Functions

(defun kimi-code-ide--has-active-session-p ()
  "Check if there's an active Kimi Code session for the current buffer."
  (when (kimi-code-ide-acp--get-current-session) t))

(defun kimi-code-ide--start-description ()
  "Dynamic description for start command based on session status."
  (if (kimi-code-ide--has-active-session-p)
      (propertize "Start new Kimi Code session (session already running)"
                  'face 'transient-inactive-value)
    "Start new Kimi Code session"))

(defun kimi-code-ide--start-if-no-session ()
  "Start Kimi Code only if no session is active for current buffer."
  (interactive)
  (if (kimi-code-ide--has-active-session-p)
      (let ((working-dir (kimi-code-ide--get-working-directory)))
        (kimi-code-ide-log "Kimi Code session already running in %s"
                             (abbreviate-file-name working-dir)))
    (kimi-code-ide)))

(defun kimi-code-ide--session-status ()
  "Return a string describing the current session status."
  (if-let ((session (kimi-code-ide-acp--get-current-session)))
      (let* ((project-dir (kimi-code-ide-acp-session-project-dir session))
             (project-name (file-name-nondirectory (directory-file-name project-dir)))
             (session-id (kimi-code-ide-acp-session-session-id session)))
        (propertize (format "Active session in [%s] - %s"
                            project-name
                            (if session-id "connected" "initializing"))
                    'face 'success))
    (propertize "No active session" 'face 'transient-inactive-value)))

(defun kimi-code-ide-toggle-window ()
  "Toggle visibility of Kimi Code window."
  (interactive)
  (kimi-code-ide-toggle))

(defun kimi-code-ide-show-version-info ()
  "Show detailed version information for Kimi Code CLI."
  (interactive)
  (if (kimi-code-ide--ensure-cli)
      (let ((version-output
             (with-temp-buffer
               (call-process kimi-code-ide-cli-path nil t nil "info")
               (buffer-string))))
        (with-output-to-temp-buffer "*Kimi Code Version*"
          (princ "Kimi Code CLI Version Information\n")
          (princ "===================================\n\n")
          (princ version-output)
          (princ "\n\nExecutable path: ")
          (princ (executable-find kimi-code-ide-cli-path))))
    (user-error "Kimi Code CLI not available")))

(defun kimi-code-ide-toggle-debug-mode ()
  "Toggle Kimi Code debug mode."
  (interactive)
  (setq kimi-code-ide-debug (not kimi-code-ide-debug))
  (kimi-code-ide-log "Debug mode %s" (if kimi-code-ide-debug "enabled" "disabled")))

;;; Transient Infix Classes

(transient-define-suffix kimi-code-ide--set-window-side (side)
  "Set window side."
  :description "Set window side"
  (interactive (list (intern (completing-read "Window side: "
                                              '("left" "right" "top" "bottom")
                                              nil t nil nil
                                              (symbol-name kimi-code-ide-window-side)))))
  (setq kimi-code-ide-window-side side)
  (kimi-code-ide-log "Window side set to %s" side))

(transient-define-suffix kimi-code-ide--set-window-width (width)
  "Set window width."
  :description "Set window width"
  (interactive (list (read-number "Window width: " kimi-code-ide-window-width)))
  (setq kimi-code-ide-window-width width)
  (kimi-code-ide-log "Window width set to %d" width))

(transient-define-suffix kimi-code-ide--set-window-height (height)
  "Set window height."
  :description "Set window height"
  (interactive (list (read-number "Window height: " kimi-code-ide-window-height)))
  (setq kimi-code-ide-window-height height)
  (kimi-code-ide-log "Window height set to %d" height))

(transient-define-suffix kimi-code-ide--set-cli-path (path)
  "Set CLI path."
  :description "Set CLI path"
  (interactive (list (read-file-name "Kimi CLI path: " nil kimi-code-ide-cli-path t)))
  (setq kimi-code-ide-cli-path path)
  (kimi-code-ide-log "CLI path set to %s" path))

(transient-define-suffix kimi-code-ide--set-cli-extra-flags (flags)
  "Set additional CLI flags."
  :description "Set additional CLI flags"
  (interactive (list (read-string "Additional CLI flags: " kimi-code-ide-cli-extra-flags)))
  (setq kimi-code-ide-cli-extra-flags flags)
  (kimi-code-ide-log "CLI extra flags set to %s" flags))

(transient-define-suffix kimi-code-ide--set-system-prompt (prompt)
  "Set the system prompt to append."
  :description "Set system prompt"
  (interactive (list (if kimi-code-ide-system-prompt
                         (read-string "System prompt (leave empty to disable): "
                                      kimi-code-ide-system-prompt)
                       (read-string "System prompt: "))))
  (setq kimi-code-ide-system-prompt (if (string-empty-p prompt) nil prompt))
  (kimi-code-ide-log "System prompt %s"
                       (if kimi-code-ide-system-prompt
                           (format "set to: %s" kimi-code-ide-system-prompt)
                         "disabled")))

;;; Transient Suffix Functions

(transient-define-suffix kimi-code-ide--toggle-focus-on-open ()
  "Toggle focus on open setting."
  (interactive)
  (setq kimi-code-ide-focus-on-open (not kimi-code-ide-focus-on-open))
  (kimi-code-ide-log "Focus on open %s" (if kimi-code-ide-focus-on-open "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-focus-after-ediff ()
  "Toggle focus after ediff setting."
  (interactive)
  (setq kimi-code-ide-focus-kimi-after-ediff (not kimi-code-ide-focus-kimi-after-ediff))
  (kimi-code-ide-log "Focus after ediff %s" (if kimi-code-ide-focus-kimi-after-ediff "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-show-kimi-in-ediff ()
  "Toggle showing Kimi window during ediff."
  (interactive)
  (setq kimi-code-ide-show-kimi-window-in-ediff (not kimi-code-ide-show-kimi-window-in-ediff))
  (kimi-code-ide-log "Show Kimi in ediff %s" (if kimi-code-ide-show-kimi-window-in-ediff "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-use-side-window ()
  "Toggle use side window setting."
  (interactive)
  (setq kimi-code-ide-use-side-window (not kimi-code-ide-use-side-window))
  (kimi-code-ide-log "Use side window %s" (if kimi-code-ide-use-side-window "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-use-ide-diff ()
  "Toggle IDE diff viewer setting."
  (interactive)
  (setq kimi-code-ide-use-ide-diff (not kimi-code-ide-use-ide-diff))
  (kimi-code-ide-log "IDE diff viewer %s" (if kimi-code-ide-use-ide-diff "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-switch-tab-on-ediff ()
  "Toggle tab switching on ediff setting."
  (interactive)
  (setq kimi-code-ide-switch-tab-on-ediff (not kimi-code-ide-switch-tab-on-ediff))
  (kimi-code-ide-log "Switch tab on ediff %s" (if kimi-code-ide-switch-tab-on-ediff "enabled" "disabled")))

(transient-define-suffix kimi-code-ide--toggle-cli-debug ()
  "Toggle CLI debug mode."
  (interactive)
  (setq kimi-code-ide-cli-debug (not kimi-code-ide-cli-debug))
  (kimi-code-ide-log "CLI debug mode %s" (if kimi-code-ide-cli-debug "enabled" "disabled")))

(defun kimi-code-ide--save-config ()
  "Save current configuration to custom file."
  (interactive)
  (customize-save-variable 'kimi-code-ide-window-side kimi-code-ide-window-side)
  (customize-save-variable 'kimi-code-ide-window-width kimi-code-ide-window-width)
  (customize-save-variable 'kimi-code-ide-window-height kimi-code-ide-window-height)
  (customize-save-variable 'kimi-code-ide-focus-on-open kimi-code-ide-focus-on-open)
  (customize-save-variable 'kimi-code-ide-focus-kimi-after-ediff kimi-code-ide-focus-kimi-after-ediff)
  (customize-save-variable 'kimi-code-ide-show-kimi-window-in-ediff kimi-code-ide-show-kimi-window-in-ediff)
  (customize-save-variable 'kimi-code-ide-use-ide-diff kimi-code-ide-use-ide-diff)
  (customize-save-variable 'kimi-code-ide-switch-tab-on-ediff kimi-code-ide-switch-tab-on-ediff)
  (customize-save-variable 'kimi-code-ide-use-side-window kimi-code-ide-use-side-window)
  (customize-save-variable 'kimi-code-ide-cli-path kimi-code-ide-cli-path)
  (customize-save-variable 'kimi-code-ide-cli-extra-flags kimi-code-ide-cli-extra-flags)
  (customize-save-variable 'kimi-code-ide-system-prompt kimi-code-ide-system-prompt)
  (kimi-code-ide-log "Configuration saved to custom file"))

;;; Transient Menus

;;;###autoload (autoload 'kimi-code-ide-menu "kimi-code-ide-transient" "Kimi Code IDE main menu." t)
(transient-define-prefix kimi-code-ide-menu ()
  "Kimi Code IDE main menu."
  [:description kimi-code-ide--session-status]
  ["Kimi Code IDE"
   ["Session Management"
    ("s" kimi-code-ide--start-if-no-session :description kimi-code-ide--start-description)
    ("r" "Resume session" kimi-code-ide-resume)
    ("q" "Stop current session" kimi-code-ide-stop)
    ("l" "List all sessions" kimi-code-ide-list-sessions)]
   ["Navigation"
    ("b" "Switch to Kimi buffer" kimi-code-ide-switch-to-buffer)
    ("w" "Toggle window visibility" kimi-code-ide-toggle-window)
    ("W" "Toggle recent window" kimi-code-ide-toggle-recent)]
   ["Interaction"
    ("p" "Send prompt from minibuffer" kimi-code-ide-send-prompt)
    ("c" "Cancel current prompt" kimi-code-ide-cancel-prompt)]
   ["Submenus"
    ("C" "Configuration" kimi-code-ide-config-menu)
    ("d" "Debugging" kimi-code-ide-debug-menu)]])

(transient-define-prefix kimi-code-ide-config-menu ()
  "Kimi Code configuration menu."
  ["Kimi Code Configuration"
   ["Window Settings"
    ("s" "Set window side" kimi-code-ide--set-window-side)
    ("w" "Set window width" kimi-code-ide--set-window-width)
    ("h" "Set window height" kimi-code-ide--set-window-height)
    ("f" "Toggle focus on open" kimi-code-ide--toggle-focus-on-open
     :description (lambda () (format "Focus on open (%s)"
                                     (if kimi-code-ide-focus-on-open "ON" "OFF"))))
    ("e" "Toggle focus after ediff" kimi-code-ide--toggle-focus-after-ediff
     :description (lambda () (format "Focus after ediff (%s)"
                                     (if kimi-code-ide-focus-kimi-after-ediff "ON" "OFF"))))
    ("E" "Toggle show Kimi in ediff" kimi-code-ide--toggle-show-kimi-in-ediff
     :description (lambda () (format "Show Kimi in ediff (%s)"
                                     (if kimi-code-ide-show-kimi-window-in-ediff "ON" "OFF"))))
    ("i" "Toggle IDE diff viewer" kimi-code-ide--toggle-use-ide-diff
     :description (lambda () (format "IDE diff viewer (%s)"
                                     (if kimi-code-ide-use-ide-diff "ON" "OFF"))))
    ("t" "Toggle tab switching on ediff" kimi-code-ide--toggle-switch-tab-on-ediff
     :description (lambda () (format "Tab switch on ediff (%s)"
                                     (if kimi-code-ide-switch-tab-on-ediff "ON" "OFF"))))
    ("u" "Toggle side window" kimi-code-ide--toggle-use-side-window
     :description (lambda () (format "Use side window (%s)"
                                     (if kimi-code-ide-use-side-window "ON" "OFF"))))]
   ["CLI Settings"
    ("p" "Set CLI path" kimi-code-ide--set-cli-path)
    ("x" "Set extra CLI flags" kimi-code-ide--set-cli-extra-flags)
    ("a" "Set system prompt" kimi-code-ide--set-system-prompt)]]
  ["Save"
   ("S" "Save configuration" kimi-code-ide--save-config)])

(transient-define-prefix kimi-code-ide-debug-menu ()
  "Kimi Code debug menu."
  ["Kimi Code Debug"
   ["Status"
    ("v" "Show version info" kimi-code-ide-show-version-info)]
   ["Debug Settings"
    ("d" "Toggle debug mode" kimi-code-ide-toggle-debug-mode
     :description (lambda () (format "Debug mode (%s)"
                                     (if kimi-code-ide-debug "ON" "OFF"))))
    ("D" "Toggle CLI debug mode" kimi-code-ide--toggle-cli-debug
     :description (lambda () (format "CLI debug mode (%s)"
                                     (if kimi-code-ide-cli-debug "ON" "OFF"))))]
   ["Debug Logs"
    ("l" "Show debug log" kimi-code-ide-show-debug)
    ("c" "Clear debug log" kimi-code-ide-clear-debug)]])

(provide 'kimi-code-ide-transient)

;;; kimi-code-ide-transient.el ends here
