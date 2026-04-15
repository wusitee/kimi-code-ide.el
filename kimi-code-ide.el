;;; kimi-code-ide.el --- Kimi Code integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (acp "0.11.0") (transient "0.9.0") (web-server "0.1.2"))
;; Keywords: ai, kimi, code, assistant, acp

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

;; Kimi Code IDE integration for Emacs provides seamless integration
;; with Kimi Code CLI through the Agent Client Protocol (ACP).
;;
;; Features:
;; - Automatic project detection and session management
;; - ACP protocol implementation for IDE integration
;; - Tool support for file operations, editor state, and workspace info
;; - Extensible MCP tools server for accessing Emacs commands
;; - Diagnostic integration with Flycheck and Flymake
;; - Advanced diff view with ediff integration
;; - Selection and buffer tracking for better context awareness
;;
;; Usage:
;; M-x kimi-code-ide - Start Kimi Code for current project
;; M-x kimi-code-ide-stop - Stop Kimi Code for current project
;; M-x kimi-code-ide-switch-to-buffer - Switch to project's Kimi buffer
;; M-x kimi-code-ide-list-sessions - List all active sessions
;; M-x kimi-code-ide-send-prompt - Send prompt to Kimi from minibuffer

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'org)
(require 'kimi-code-ide-debug)
(require 'kimi-code-ide-acp)
(require 'kimi-code-ide-tools-server)

(declare-function kimi-code-ide-handlers-open-diff "kimi-code-ide-handlers"
                  (old-file-path new-file-contents tab-name))
(declare-function evil-insert-state "evil" ())

;; External variable declarations
(defvar vterm-shell)
(defvar vterm-environment)
(defvar vterm--process)

;; External function declarations for vterm
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string))
(declare-function vterm-send-escape "vterm" ())
(declare-function vterm-send-return "vterm" ())
(declare-function vterm--window-adjust-process-window-size "vterm" (&optional frame))

;;; Customization

(defgroup kimi-code-ide nil
  "Kimi Code integration for Emacs."
  :group 'tools
  :prefix "kimi-code-ide-")

(defcustom kimi-code-ide-cli-path "kimi"
  "Path to the Kimi Code CLI executable."
  :type 'string
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-buffer-name-function #'kimi-code-ide--default-buffer-name
  "Function to generate buffer names for Kimi Code sessions.
The function is called with one argument, the working directory,
and should return a string to use as the buffer name."
  :type 'function
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-cli-debug nil
  "When non-nil, launch Kimi Code with debug output."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-cli-extra-flags ""
  "Additional flags to pass to the Kimi Code CLI.
This should be a string of space-separated flags."
  :type 'string
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-system-prompt nil
  "System prompt to append to Kimi's default system prompt.
When non-nil, appended via ACP session meta."
  :type '(choice (const :tag "Disabled" nil)
          (string :tag "System prompt text"))
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-window-side 'right
  "Side of the frame where the Kimi Code window should appear.
Can be `'left', `'right', `'top', or `'bottom'."
  :type '(choice (const :tag "Left" left)
          (const :tag "Right" right)
          (const :tag "Top" top)
          (const :tag "Bottom" bottom))
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-window-width 100
  "Body width of the Kimi Code side window when opened on left or right."
  :type 'integer
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-window-height 20
  "Height of the Kimi Code side window when opened on top or bottom."
  :type 'integer
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-focus-on-open t
  "Whether to focus the Kimi Code window when it opens."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-focus-kimi-after-ediff t
  "Whether to focus the Kimi Code window after opening ediff."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-show-kimi-window-in-ediff t
  "Whether to show the Kimi Code side window when viewing diffs."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-use-ide-diff t
  "Whether to use IDE diff viewer for file differences.
When non-nil (default), Kimi Code will open an IDE diff viewer
(ediff) when showing file changes."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-switch-tab-on-ediff t
  "Whether to switch back to Kimi's original tab when opening ediff."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-use-side-window t
  "Whether to display Kimi Code in a side window."
  :type 'boolean
  :group 'kimi-code-ide)

(defcustom kimi-code-ide-terminal-backend 'vterm
  "Terminal backend to use for Kimi Code terminal tool calls.
Can be either `vterm' or `eat'."
  :type '(choice (const :tag "vterm" vterm)
          (const :tag "eat" eat))
  :group 'kimi-code-ide)

;;; Variables

(defvar kimi-code-ide--cli-available nil
  "Whether Kimi Code CLI is available and detected.")

(defvar kimi-code-ide--session-ids (make-hash-table :test 'equal)
  "Hash table mapping project/directory roots to their session IDs.")

(defvar kimi-code-ide--last-accessed-buffer nil
  "The most recently accessed Kimi Code buffer.")

(defvar-local kimi-code-ide--project-dir nil
  "Project directory for the current Kimi Code buffer.")

(defvar-local kimi-code-ide--response-marker nil
  "Marker for the current streaming response position.")

(defvar-local kimi-code-ide--response-raw-text nil
  "Accumulated raw Markdown text for the current streaming response.")

(defvar-local kimi-code-ide--input-project-dir nil
  "Project directory for the current input buffer.")

(defvar kimi-code-ide--cleanup-in-progress nil
  "Flag to prevent recursive cleanup calls.")

;;; Helper Functions

(defun kimi-code-ide--default-buffer-name (directory)
  "Generate default buffer name for DIRECTORY."
  (format "*kimi-code[%s]*"
          (file-name-nondirectory (directory-file-name directory))))

(defun kimi-code-ide--get-working-directory ()
  "Get the current working directory (project root or current directory)."
  (if-let ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun kimi-code-ide--get-buffer-name (&optional directory)
  "Get the buffer name for the Kimi Code session in DIRECTORY."
  (funcall kimi-code-ide-buffer-name-function
           (or directory (kimi-code-ide--get-working-directory))))

(defun kimi-code-ide--get-input-buffer-name (&optional directory)
  "Get the input buffer name for the Kimi Code session in DIRECTORY."
  (format "%s-input" (kimi-code-ide--get-buffer-name directory)))

(defun kimi-code-ide--display-buffer-in-side-window (buffer)
  "Display BUFFER in a side window, together with its input buffer."
  (let* ((side kimi-code-ide-window-side)
         (window-parameters '((no-delete-other-windows . t)))
         (conv-window
          (if kimi-code-ide-use-side-window
              (display-buffer-in-side-window
               buffer
               `((side . ,side)
                 (slot . 0)
                 ,@(when (memq side '(left right))
                     `((window-width
                        . ,(lambda (win)
                             (let ((delta (- kimi-code-ide-window-width
                                             (window-body-width win))))
                               (unless (zerop delta)
                                 (window-resize win delta t)))))))
                 ,@(when (memq side '(top bottom))
                     `((window-height . ,kimi-code-ide-window-height)))
                 (window-parameters . ,window-parameters)))
            (display-buffer buffer)))
         (project-dir (buffer-local-value 'kimi-code-ide--project-dir buffer))
         (input-buffer (when project-dir
                         (kimi-code-ide--ensure-input-buffer project-dir))))
    (when (and conv-window input-buffer)
      (unless (get-buffer-window input-buffer)
        (if kimi-code-ide-use-side-window
            (display-buffer-in-side-window
             input-buffer
             `((side . ,side)
               (slot . 1)
               ,@(when (memq side '(left right))
                   `((window-width
                      . ,(lambda (win)
                           (let ((delta (- kimi-code-ide-window-width
                                           (window-body-width win))))
                             (unless (zerop delta)
                               (window-resize win delta t)))))))
               (window-height . 4)
               (window-parameters . ,window-parameters)))
          (let ((input-win (split-window conv-window nil 'below)))
            (set-window-buffer input-win input-buffer)
            (set-window-text-height input-win 4)))))
    (setq kimi-code-ide--last-accessed-buffer buffer)
    (when (and conv-window kimi-code-ide-focus-on-open)
      (if-let ((input-win (get-buffer-window input-buffer)))
          (select-window input-win)
        (select-window conv-window)))
    (when (and conv-window
               kimi-code-ide-use-side-window
               (memq kimi-code-ide-window-side '(top bottom)))
      (set-window-text-height conv-window kimi-code-ide-window-height)
      (set-window-dedicated-p conv-window t))
    conv-window))

;;; Buffer Rendering

(defun kimi-code-ide--ensure-buffer (project-dir)
  "Get or create the Kimi Code conversation buffer for PROJECT-DIR."
  (let ((buffer-name (kimi-code-ide--get-buffer-name project-dir)))
    (if-let ((buffer (get-buffer buffer-name)))
        buffer
      (let ((buffer (get-buffer-create buffer-name)))
        (with-current-buffer buffer
          (kimi-code-ide-mode)
          (setq kimi-code-ide--project-dir project-dir)
          (kimi-code-ide--render-welcome project-dir)
          (add-hook 'kill-buffer-hook
                    (lambda ()
                      (kimi-code-ide--cleanup-on-exit project-dir))
                    nil t))
        buffer))))

(defun kimi-code-ide--ensure-input-buffer (project-dir)
  "Get or create the Kimi Code input buffer for PROJECT-DIR."
  (let ((buffer-name (kimi-code-ide--get-input-buffer-name project-dir)))
    (if-let ((buffer (get-buffer buffer-name)))
        buffer
      (let ((buffer (get-buffer-create buffer-name)))
        (with-current-buffer buffer
          (kimi-code-ide-input-mode)
          (setq default-directory project-dir)
          (setq kimi-code-ide--input-project-dir project-dir)
          (setq buffer-read-only nil)
          (erase-buffer))
        buffer))))

(defun kimi-code-ide--markdown-to-org (text)
  "Convert lightweight Markdown in TEXT to Org syntax."
  (with-temp-buffer
    (insert text)
    ;; Code blocks first (before inline code eats backticks)
    (goto-char (point-min))
    (while (re-search-forward (concat "^```\\(?:\\(.*\\)\\)?\\(" "\n" "\\(?:.*\\(?:\n\\|\\'\\)\\)*?\\)```") nil t)
      (let ((lang (or (match-string 1) ""))
            (content (match-string 2)))
        (replace-match (concat "#+begin_src " lang content "#+end_src") t t)))
    ;; Links [text](url)
    (goto-char (point-min))
    (while (re-search-forward "\\[\\([^]]+\\)\\](\\([^)]+\\))" nil t)
      (let ((text (match-string 1))
            (url (match-string 2)))
        (replace-match (format "[[%s][%s]]" url text) t t)))
    ;; Inline code
    (goto-char (point-min))
    (while (re-search-forward "`\\([^`]+\\)`" nil t)
      (let ((code (match-string 1)))
        (replace-match (concat "=" code "=") t t)))
    ;; Bold **text**
    (goto-char (point-min))
    (while (re-search-forward "\\*\\*\\([^*]+\\)\\*\\*" nil t)
      (let ((content (match-string 1)))
        (replace-match (concat "*" content "*") t t)))
    ;; Headers
    (goto-char (point-min))
    (while (re-search-forward "^\\(#\\{1,6\\}\\)[ \t]+\\(.+\\)$" nil t)
      (let ((level (length (match-string 1)))
            (title (match-string 2)))
        (replace-match (format "%s %s" (make-string level ?*) title) t t)))
    (buffer-string)))

(defun kimi-code-ide--insert-read-only (text &rest props)
  "Insert TEXT with read-only property and optional face PROPS."
  (insert (apply #'propertize text 'read-only t 'rear-nonsticky t props)))

(defun kimi-code-ide--flush-response-raw-text ()
  "Convert accumulated raw Markdown to Org and clear the marker."
  (when (and kimi-code-ide--response-marker
             kimi-code-ide--response-raw-text
             (> (length kimi-code-ide--response-raw-text) 0))
    (let ((inhibit-read-only t))
      (goto-char kimi-code-ide--response-marker)
      (delete-region (point) (point-max))
      (kimi-code-ide--insert-read-only
       (kimi-code-ide--markdown-to-org kimi-code-ide--response-raw-text))
      (setq kimi-code-ide--response-raw-text nil)))
  (when kimi-code-ide--response-marker
    (setq kimi-code-ide--response-marker nil)))

(defun kimi-code-ide--render-welcome (project-dir)
  "Render welcome message for PROJECT-DIR."
  (erase-buffer)
  (kimi-code-ide--insert-read-only
   (format "* Kimi Code IDE — %s\n\n"
           (file-name-nondirectory (directory-file-name project-dir))))
  (setq kimi-code-ide--response-marker nil)
  (setq kimi-code-ide--response-raw-text nil))

(defun kimi-code-ide--render-function (project-dir)
  "Return the render function for PROJECT-DIR."
  (let ((buffer (kimi-code-ide--ensure-buffer project-dir)))
    (lambda (type data)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (kimi-code-ide--render-in-buffer type data))))))

(defun kimi-code-ide--render-in-buffer (type data)
  "Render DATA of TYPE in the current buffer."
  (let ((inhibit-read-only t))
    (pcase type
      ('user-prompt
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "* You\n")
       (kimi-code-ide--insert-read-only (kimi-code-ide--markdown-to-org data))
       (kimi-code-ide--insert-read-only "\n-----\n\n"))
      ('agent-text
       (unless kimi-code-ide--response-marker
         (goto-char (point-max))
         (kimi-code-ide--insert-read-only "* Kimi\n")
         (setq kimi-code-ide--response-marker (point-marker))
         (set-marker-insertion-type kimi-code-ide--response-marker t)
         (setq kimi-code-ide--response-raw-text ""))
       (goto-char kimi-code-ide--response-marker)
       (setq kimi-code-ide--response-raw-text
             (concat kimi-code-ide--response-raw-text data))
       (kimi-code-ide--insert-read-only data))
      ('tool-call
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (let-alist data
         (kimi-code-ide--insert-read-only "#+BEGIN_QUOTE\n")
         (kimi-code-ide--insert-read-only
          (format "🔧 %s (%s)\n" (or .title "Tool") .status))
         ;; Show useful params when available
         (let* ((params (when (listp data) (map-elt data 'params)))
                (cmd (when (listp params) (map-elt params 'command)))
                (args (when (listp params) (map-elt params 'args)))
                (path (when (listp params) (map-elt params 'path)))
                (file (when (listp params) (map-elt params 'file))))
           (when cmd
             (kimi-code-ide--insert-read-only
              (format "  Command: %s\n"
                      (if (and args (listp args) (> (length args) 0))
                          (mapconcat #'shell-quote-argument (cons cmd args) " ")
                        cmd))))
           (when (or path file)
             (kimi-code-ide--insert-read-only
              (format "  Path: %s\n" (or path file)))))
         (when (and (vectorp .content) (> (length .content) 0))
           (dolist (item (append .content nil))
             (let-alist item
               (when (and (equal .type "text") .text (> (length .text) 0))
                 (kimi-code-ide--insert-read-only (format "  → %s\n" .text))))))
         (kimi-code-ide--insert-read-only "#+END_QUOTE\n\n")))
      ('plan
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_QUOTE\n")
       (kimi-code-ide--insert-read-only "[Plan]\n")
       (dolist (entry data)
         (let-alist entry
           (kimi-code-ide--insert-read-only (format "- %s [%s]\n" .content .status))))
       (kimi-code-ide--insert-read-only "#+END_QUOTE\n\n"))
      ('diff
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_QUOTE\n")
       (kimi-code-ide--insert-read-only "[Diff suggestion]\n")
       (when kimi-code-ide-use-ide-diff
         (let-alist data
           (condition-case err
               (kimi-code-ide-handlers-open-diff .path .new-text .path)
             (error
              (kimi-code-ide-debug "Failed to open diff: %s" err)
              (kimi-code-ide--insert-read-only (format "File: %s\n" .path))))))
       (kimi-code-ide--insert-read-only "#+END_QUOTE\n\n"))
      ('prompt-complete
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "\n\n"))
      ('prompt-error
       (kimi-code-ide--flush-response-raw-text)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_CENTER\n")
       (kimi-code-ide--insert-read-only
        (format "[Error: %s]\n" (map-elt data 'message)))
       (kimi-code-ide--insert-read-only "#+END_CENTER\n\n"))
      ('session-ready
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_CENTER\n")
       (kimi-code-ide--insert-read-only "[Session ready]\n")
       (kimi-code-ide--insert-read-only "#+END_CENTER\n\n")))
    ;; Keep window point at end if visible
    (when-let ((win (get-buffer-window (current-buffer))))
      (set-window-point win (point-max)))))

;;; Mode Definitions

(defvar-keymap kimi-code-ide-input-mode-map
  :doc "Keymap for `kimi-code-ide-input-mode'."
  "C-c C-c" #'kimi-code-ide--submit-input-buffer
  "C-c C-p" #'kimi-code-ide-send-prompt
  "C-c C-q" #'kimi-code-ide-stop)

(define-derived-mode kimi-code-ide-input-mode text-mode "Kimi Input"
  "Major mode for Kimi Code IDE input buffers."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type 'bar)
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-insert-state)))

(define-derived-mode kimi-code-ide-mode org-mode "Kimi Code"
  "Major mode for Kimi Code IDE conversation buffers."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type 'bar)
  (buffer-disable-undo)
  (when (boundp 'org-ctrl-k-protect-subtree)
    (setq-local org-ctrl-k-protect-subtree nil))
  (when (and (boundp 'evil-mode) evil-mode)
    (evil-insert-state)))

(defun kimi-code-ide--submit-input-buffer ()
  "Submit the contents of the current input buffer as a prompt."
  (interactive)
  (unless kimi-code-ide--input-project-dir
    (user-error "Not in a Kimi Code input buffer"))
  (let ((input (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p input)
      (erase-buffer)
      (user-error "Empty prompt"))
    (let ((project-dir kimi-code-ide--input-project-dir))
      (erase-buffer)
      (let ((default-directory project-dir))
        (kimi-code-ide-send-prompt input)))))

;;; CLI Detection

(defun kimi-code-ide--detect-cli ()
  "Detect if Kimi Code CLI is available."
  (let ((available (condition-case nil
                       (eq (call-process kimi-code-ide-cli-path nil nil nil "info") 0)
                     (error nil))))
    (setq kimi-code-ide--cli-available available)))

(defun kimi-code-ide--ensure-cli ()
  "Ensure Kimi Code CLI is available, detect if needed."
  (unless kimi-code-ide--cli-available
    (kimi-code-ide--detect-cli))
  kimi-code-ide--cli-available)

;;; Commands

(defun kimi-code-ide--toggle-existing-window (existing-buffer working-dir)
  "Toggle visibility of EXISTING-BUFFER window for WORKING-DIR."
  (let ((window (get-buffer-window existing-buffer))
        (input-buffer (kimi-code-ide--get-input-buffer-name working-dir)))
    (if window
        (progn
          (setq kimi-code-ide--last-accessed-buffer existing-buffer)
          ;; Delete input window(s) first, then the conversation window
          (dolist (win (get-buffer-window-list input-buffer nil t))
            (ignore-errors (delete-window win)))
          (ignore-errors (delete-window window))
          (kimi-code-ide-debug "Kimi Code window hidden"))
      (progn
        (kimi-code-ide--display-buffer-in-side-window existing-buffer)
        (kimi-code-ide-debug "Kimi Code window shown")))))

(defun kimi-code-ide--cleanup-on-exit (directory)
  "Clean up Kimi Code session when it exits for DIRECTORY."
  (unless kimi-code-ide--cleanup-in-progress
    (setq kimi-code-ide--cleanup-in-progress t)
    (unwind-protect
        (progn
          (kimi-code-ide-acp-stop directory)
          (let ((session-id (gethash directory kimi-code-ide--session-ids)))
            (when session-id
              (kimi-code-ide-tools-server-session-ended session-id)
              (remhash directory kimi-code-ide--session-ids)))
          (let ((buffer-name (kimi-code-ide--get-buffer-name directory))
                (input-buffer-name (kimi-code-ide--get-input-buffer-name directory)))
            (when-let ((buffer (get-buffer buffer-name)))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (let (kill-buffer-hook kill-buffer-query-functions)
                    (kill-buffer buffer)))))
            (when-let ((input-buffer (get-buffer input-buffer-name)))
              (when (buffer-live-p input-buffer)
                (with-current-buffer input-buffer
                  (let (kill-buffer-hook kill-buffer-query-functions)
                    (kill-buffer input-buffer))))))
          (kimi-code-ide-debug "Cleaned up Kimi Code session for %s"
                               (file-name-nondirectory (directory-file-name directory))))
      (setq kimi-code-ide--cleanup-in-progress nil))))

(defun kimi-code-ide--start-session ()
  "Start a Kimi Code ACP session for the current project."
  (unless (kimi-code-ide--ensure-cli)
    (user-error "Kimi Code CLI not available.  Please install it and ensure it's in PATH"))
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name))
         (existing-buffer (get-buffer buffer-name))
         (session (kimi-code-ide-acp--get-session-for-project working-dir)))
    (if (and existing-buffer
             (buffer-live-p existing-buffer)
             session
             (kimi-code-ide-acp-session-initialized session))
        (kimi-code-ide--toggle-existing-window existing-buffer working-dir)
      (let* ((buffer (kimi-code-ide--ensure-buffer working-dir))
             (render-fn (kimi-code-ide--render-function working-dir)))
        (kimi-code-ide-acp--set-render-function working-dir render-fn)
        (kimi-code-ide--display-buffer-in-side-window buffer)
        (kimi-code-ide-acp-start
         buffer working-dir
         (lambda (session-id)
           (kimi-code-ide--render-in-buffer 'session-ready session-id)
           (kimi-code-ide-log "Kimi Code started in %s (session: %s)"
                              (file-name-nondirectory (directory-file-name working-dir))
                              session-id)))))))

;;;###autoload
(defun kimi-code-ide ()
  "Run Kimi Code for the current project or directory."
  (interactive)
  (kimi-code-ide--start-session))

;;;###autoload
(defun kimi-code-ide-stop ()
  "Stop the Kimi Code session for the current project or directory."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name))
         (input-buffer-name (kimi-code-ide--get-input-buffer-name working-dir)))
    (kimi-code-ide-acp-stop working-dir)
    (when-let ((buffer (get-buffer buffer-name)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let (kill-buffer-hook kill-buffer-query-functions)
            (kill-buffer buffer)))))
    (when-let ((input-buffer (get-buffer input-buffer-name)))
      (when (buffer-live-p input-buffer)
        (with-current-buffer input-buffer
          (let (kill-buffer-hook kill-buffer-query-functions)
            (kill-buffer input-buffer)))))
    (kimi-code-ide-log "Stopped Kimi Code in %s"
                       (file-name-nondirectory (directory-file-name working-dir)))))

;;;###autoload
(defun kimi-code-ide-switch-to-buffer ()
  "Switch to the Kimi Code buffer for the current project."
  (interactive)
  (let* ((buffer-name (kimi-code-ide--get-buffer-name))
         (input-buffer-name (kimi-code-ide--get-input-buffer-name))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (if-let ((window (get-buffer-window buffer)))
            (if-let ((input-win (get-buffer-window (get-buffer input-buffer-name))))
                (select-window input-win)
              (select-window window))
          (kimi-code-ide--display-buffer-in-side-window buffer))
      (user-error "No Kimi Code session for this project.  Use M-x kimi-code-ide to start one"))))

;;;###autoload
(defun kimi-code-ide-list-sessions ()
  "List all active Kimi Code sessions and switch to selected one."
  (interactive)
  (let ((sessions '()))
    (maphash (lambda (directory session)
               (when (and session (kimi-code-ide-acp-session-initialized session))
                 (push (cons (abbreviate-file-name directory)
                             directory)
                       sessions)))
             kimi-code-ide-acp--sessions)
    (if sessions
        (let ((choice (completing-read "Switch to Kimi Code session: "
                                       sessions nil t)))
          (when choice
            (let* ((directory (alist-get choice sessions nil nil #'string=))
                   (buffer-name (funcall kimi-code-ide-buffer-name-function directory)))
              (if-let ((buffer (get-buffer buffer-name)))
                  (kimi-code-ide--display-buffer-in-side-window buffer)
                (user-error "Buffer for session %s no longer exists" choice)))))
      (kimi-code-ide-log "No active Kimi Code sessions"))))

;;;###autoload
(defun kimi-code-ide-send-prompt (&optional prompt)
  "Send a prompt to the Kimi Code agent.
When called interactively, reads a prompt from the minibuffer.
When called programmatically, sends the given PROMPT string."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name))
         (buffer (get-buffer buffer-name)))
    (unless (and buffer (buffer-live-p buffer))
      (user-error "No Kimi Code session for this project.  Use M-x kimi-code-ide to start one"))
    (let ((prompt-to-send (or prompt (read-string "Kimi prompt: "))))
      (when (not (string-empty-p prompt-to-send))
        (with-current-buffer buffer
          (kimi-code-ide--render-in-buffer 'user-prompt prompt-to-send))
        (kimi-code-ide-acp--send-prompt working-dir prompt-to-send)
        (kimi-code-ide-debug "Sent prompt to Kimi: %s" prompt-to-send)))))

;;;###autoload
(defun kimi-code-ide-cancel-prompt ()
  "Cancel the current prompt turn."
  (interactive)
  (let ((working-dir (kimi-code-ide--get-working-directory)))
    (kimi-code-ide-acp--cancel-prompt working-dir)
    (kimi-code-ide-log "Cancelled current prompt")))

;;;###autoload
(defun kimi-code-ide-toggle ()
  "Toggle visibility of Kimi Code window for the current project."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (kimi-code-ide--toggle-existing-window buffer working-dir)
      (user-error "No Kimi Code session for this project"))))

;;;###autoload
(defun kimi-code-ide-toggle-recent ()
  "Toggle visibility of the most recent Kimi Code window."
  (interactive)
  (let ((found-visible nil))
    (maphash (lambda (directory _session)
               (let* ((buffer-name (funcall kimi-code-ide-buffer-name-function directory))
                      (buffer (get-buffer buffer-name)))
                 (when (and buffer
                            (buffer-live-p buffer)
                            (get-buffer-window buffer))
                   (kimi-code-ide--toggle-existing-window buffer directory)
                   (setq found-visible t))))
             kimi-code-ide-acp--sessions)
    (cond
     (found-visible
      (message "Closed all Kimi Code windows"))
     ((and kimi-code-ide--last-accessed-buffer
           (buffer-live-p kimi-code-ide--last-accessed-buffer))
      (kimi-code-ide--display-buffer-in-side-window kimi-code-ide--last-accessed-buffer)
      (message "Opened most recent Kimi Code session"))
     (t
      (user-error "No recent Kimi Code session to toggle")))))

(provide 'kimi-code-ide)

;;; kimi-code-ide.el ends here
