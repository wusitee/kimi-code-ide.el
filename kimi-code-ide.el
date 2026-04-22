;;; kimi-code-ide.el --- Kimi Code integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (acp "0.11.0") (transient "0.9.0") (web-server "0.1.2"))
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

(defvar-local kimi-code-ide--stream-start-time nil
  "Timestamp when the current streaming response started.")

(defvar-local kimi-code-ide--stream-token-count 0
  "Estimated token count for the current streaming response.")

(defvar-local kimi-code-ide--stream-chunk-count 0
  "Number of chunks received for the current streaming response.")

(defvar-local kimi-code-ide--response-raw-text nil
  "Accumulated raw Markdown text for the current streaming response.")

(defvar-local kimi-code-ide--input-project-dir nil
  "Project directory for the current input buffer.")

(defvar kimi-code-ide--pending-resume-history (make-hash-table :test 'equal)
  "Hash table mapping project directories to pending resume history strings.")

(defvar kimi-code-ide--cleanup-in-progress nil
  "Flag to prevent recursive cleanup calls.")

(defvar kimi-code-ide-slash-commands
  '(("/help" . (:fn kimi-code-ide-slash-help :desc "Display help information"))
    ("/version" . (:fn kimi-code-ide-send-prompt :desc "Display version number"))
    ("/changelog" . (:fn kimi-code-ide-send-prompt :desc "Display the changelog"))
    ("/feedback" . (:fn kimi-code-ide-send-prompt :desc "Submit feedback"))
    ("/login" . (:fn kimi-code-ide-send-prompt :desc "Log in or configure API platform"))
    ("/logout" . (:fn kimi-code-ide-send-prompt :desc "Log out from current platform"))
    ("/model" . (:fn kimi-code-ide-send-prompt :desc "Switch models and thinking mode"))
    ("/editor" . (:fn kimi-code-ide-send-prompt :desc "Set the external editor"))
    ("/theme" . (:fn kimi-code-ide-send-prompt :desc "Switch the terminal color theme"))
    ("/reload" . (:fn kimi-code-ide-send-prompt :desc "Reload configuration file"))
    ("/debug" . (:fn kimi-code-ide-send-prompt :desc "Display debug information"))
    ("/usage" . (:fn kimi-code-ide-send-prompt :desc "Display API usage and quota"))
    ("/mcp" . (:fn kimi-code-ide-send-prompt :desc "Display connected MCP servers"))
    ("/hooks" . (:fn kimi-code-ide-send-prompt :desc "Display configured hooks"))
    ("/new" . (:fn kimi-code-ide :desc "Open Kimi Code IDE or reuse the current session"))
    ("/sessions" . (:fn kimi-code-ide-list-sessions :desc "List and switch sessions"))
    ("/title" . (:fn kimi-code-ide-send-prompt :desc "View or set session title"))
    ("/undo" . (:fn kimi-code-ide-send-prompt :desc "Roll back to previous turn"))
    ("/fork" . (:fn kimi-code-ide-send-prompt :desc "Fork session with history"))
    ("/export" . (:fn kimi-code-ide-send-prompt :desc "Export session to Markdown"))
    ("/import" . (:fn kimi-code-ide-resume :desc "Import/resume from context.jsonl"))
    ("/clear" . (:fn kimi-code-ide--clear-conversation :desc "Clear conversation buffer"))
    ("/compact" . (:fn kimi-code-ide-send-prompt :desc "Compact context manually"))
    ("/skill:" . (:fn kimi-code-ide-send-prompt :desc "Load a specific skill"))
    ("/flow:" . (:fn kimi-code-ide-send-prompt :desc "Execute a flow skill"))
    ("/add-dir" . (:fn kimi-code-ide-send-prompt :desc "Add directory to workspace"))
    ("/btw" . (:fn kimi-code-ide-send-prompt :desc "Ask a side question"))
    ("/init" . (:fn kimi-code-ide-send-prompt :desc "Analyze project and generate AGENTS.md"))
    ("/plan" . (:fn kimi-code-ide-send-prompt :desc "Toggle plan mode"))
    ("/task" . (:fn kimi-code-ide-send-prompt :desc "Open interactive task browser"))
    ("/yolo" . (:fn kimi-code-ide-send-prompt :desc "Toggle YOLO mode"))
    ("/web" . (:fn kimi-code-ide-send-prompt :desc "Switch to Web UI"))
    ("/vis" . (:fn kimi-code-ide-send-prompt :desc "Switch to Agent Tracing Visualizer"))
    ("/stop" . (:fn kimi-code-ide-stop :desc "Stop the current session"))
    ("/cancel" . (:fn kimi-code-ide-cancel-prompt :desc "Cancel current prompt")))
  "Alist of slash command names to their metadata.
Each value is a plist with :fn (the function to call) and :desc
(description for completion annotations).")

;;; Helper Functions

(defun kimi-code-ide--default-buffer-name (directory)
  "Generate default buffer name for DIRECTORY."
  (format "*kimi-code[%s]*"
          (file-name-nondirectory (directory-file-name directory))))

(defun kimi-code-ide--kimi-session-dir (project-dir)
  "Return the Kimi sessions directory hash for PROJECT-DIR."
  (expand-file-name
   (format "sessions/%s" (md5 project-dir))
   (expand-file-name "~/.kimi")))

(defun kimi-code-ide--latest-kimi-context-file (project-dir)
  "Return the most recent context.jsonl file for PROJECT-DIR with turns, or nil."
  (let* ((sessions-dir (kimi-code-ide--kimi-session-dir project-dir))
         (context-files
          (when (file-directory-p sessions-dir)
            (directory-files-recursively sessions-dir "context\\.jsonl$" t))))
    (when context-files
      (setq context-files
            (sort context-files
                  (lambda (a b)
                    (> (float-time (file-attribute-modification-time (file-attributes a)))
                       (float-time (file-attribute-modification-time (file-attributes b)))))))
      (cl-loop for file in context-files
               when (kimi-code-ide--parse-context-jsonl file)
               return file))))

(defun kimi-code-ide--read-kimi-session-turns (project-dir)
  "Return parsed conversation turns from Kimi's session files for PROJECT-DIR.
Each turn is a cons cell (USER-TEXT . ASSISTANT-TEXT).  Returns nil
if no history is found."
  (when-let ((file (kimi-code-ide--latest-kimi-context-file project-dir)))
    (kimi-code-ide--parse-context-jsonl file)))

(defun kimi-code-ide--format-session-turns (turns)
  "Format TURNS into a string suitable for prompt injection."
  (when turns
    (concat "Continuing our previous conversation:\n\n"
            (mapconcat
             (lambda (turn)
               (concat "[User]:\n" (car turn)
                       "\n\n[Kimi]:\n" (cdr turn)))
             turns "\n\n")
            "\n\nPlease continue from here.\n\n")))

(defun kimi-code-ide--read-kimi-session-history (project-dir)
  "Read conversation history from Kimi's session files for PROJECT-DIR.
Returns a formatted string suitable for prompt injection, or nil if
no history is found."
  (kimi-code-ide--format-session-turns (kimi-code-ide--read-kimi-session-turns project-dir)))

(defun kimi-code-ide--parse-context-jsonl (file)
  "Parse Kimi's context.jsonl FILE and return a list of (user . assistant) turns."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((turns '())
            (current-user nil)
            (current-assistant '()))
        (goto-char (point-min))
        (while (not (eobp))
          (skip-chars-forward " \t\n\r")
          (when (not (eobp))
            (condition-case nil
                (let ((obj (json-parse-buffer :object-type 'alist
                                              :array-type 'list
                                              :null-object nil)))
                  (let ((role (cdr (assq 'role obj)))
                        (content (cdr (assq 'content obj))))
                    (cond
                     ((equal role "user")
                      (when (or current-user current-assistant)
                        (push (cons (or current-user "")
                                    (string-join (nreverse current-assistant) "\n\n"))
                              turns))
                      (setq current-user (kimi-code-ide--extract-user-text content))
                      (setq current-assistant '()))
                     ((equal role "assistant")
                      (let ((text (kimi-code-ide--extract-assistant-text content)))
                        (when text
                          (push text current-assistant))))
                     ((equal role "tool")
                      (when (stringp content)
                        (push (format "[Tool result]\n%s" content) current-assistant))))))
              (error (goto-char (point-max))))))
        (when (or current-user current-assistant)
          (push (cons (or current-user "") (string-join (nreverse current-assistant) "\n\n")) turns))
        ;; Filter out turns where both are empty
        (setq turns (seq-filter (lambda (turn) (or (> (length (car turn)) 0)
                                                  (> (length (cdr turn)) 0)))
                               (nreverse turns)))
        (when (> (length turns) 0)
          turns)))))

(defun kimi-code-ide--extract-user-text (content)
  "Extract clean user text from CONTENT alist or string."
  (cond
   ((stringp content)
    (if (kimi-code-ide--system-noise-p content) "" content))
   ((listp content)
    (string-join
     (seq-filter
      (lambda (s) (> (length s) 0))
      (mapcar (lambda (part)
                (when (equal (cdr (assq 'type part)) "text")
                  (let ((text (cdr (assq 'text part))))
                    (if (and (stringp text) (kimi-code-ide--system-noise-p text))
                        ""
                      (or text "")))))
              content))
     "\n\n"))
   (t "")))

(defun kimi-code-ide--extract-assistant-text (content)
  "Extract clean assistant text from CONTENT alist or string."
  (cond
   ((stringp content) content)
   ((listp content)
    (string-join
     (seq-filter
      (lambda (s) (> (length s) 0))
      (mapcar (lambda (part)
                (when (equal (cdr (assq 'type part)) "text")
                  (or (cdr (assq 'text part)) "")))
              content))
     "\n\n"))
   (t nil)))

(defun kimi-code-ide--system-noise-p (text)
  "Return non-nil if TEXT is Kimi internal system metadata."
  (or (string-match-p "<system>" text)
      (string-match-p "<current_focus>" text)
      (string-match-p "<environment>" text)
      (string-match-p "<completed_tasks>" text)
      (string-match-p "<active_issues>" text)
      (string-match-p "<code_state>" text)
      (string-match-p "<important_context>" text)
      (string-match-p "<image path=" text)
      (string-match-p "Previous context has been compacted" text)))

(defun kimi-code-ide--extract-conversation-history (buffer)
  "Extract user/Kimi turns from BUFFER as a single string."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((turns '()))
        (when (re-search-forward "^\\* \\(You\\|Kimi\\)\\(?:[ \t]\\|$\\)" nil t)
          (goto-char (match-beginning 0))
          (while (looking-at "^\\* \\(You\\|Kimi\\)\\(?:[ \t]\\|$\\)")
            (let ((speaker (match-string 1))
                  (start (match-end 0)))
              (forward-line)
              (let ((end (or (and (re-search-forward "^\\* \\(You\\|Kimi\\)\\(?:[ \t]\\|$\\)" nil t)
                                  (match-beginning 0))
                             (point-max))))
                (let ((text (string-trim (buffer-substring-no-properties start end))))
                  (push (format "[%s]:\n%s" speaker text) turns))
                (when (< (point) end)
                  (goto-char end)))))
          (when turns
            (concat "Continuing our previous conversation:\n\n"
                    (mapconcat #'identity (nreverse turns) "\n\n")
                    "\n\nPlease continue from here.\n\n")))))))

(defun kimi-code-ide--get-working-directory ()
  "Get the current working directory (project root or current directory).
Trailing slash is stripped to match Kimi CLI's path normalization."
  (directory-file-name
   (if-let ((project (project-current)))
       (expand-file-name (project-root project))
     (expand-file-name default-directory))))

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

;;;###autoload
(defun kimi-code-ide--clear-conversation ()
  "Clear the conversation buffer for the current project."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer (get-buffer (kimi-code-ide--get-buffer-name working-dir))))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (kimi-code-ide--render-welcome working-dir))))
    (kimi-code-ide-log "Cleared conversation buffer")))

;;;###autoload
(defun kimi-code-ide-slash-help ()
  "Show available slash commands in a temporary buffer."
  (interactive)
  (let ((commands (mapcar (lambda (entry)
                            (format "  %s — %s"
                                    (car entry)
                                    (plist-get (cdr entry) :desc)))
                          kimi-code-ide-slash-commands)))
    (with-output-to-temp-buffer "*Kimi Code Slash Commands*"
      (princ "Available slash commands:\n\n")
      (princ (string-join commands "\n"))
      (princ "\n"))))

(defun kimi-code-ide--slash-completion-at-point ()
  "Completion-at-point function for slash commands in input buffers.
Returns a completion table when point is within the initial slash command."
  (let ((bol-slash (save-excursion
                     (beginning-of-line)
                     (when (eq (char-after) ?/)
                       (point)))))
    (when bol-slash
      (let* ((start (1+ bol-slash))
             (end (save-excursion
                    (goto-char start)
                    (skip-chars-forward "^ \t\n")
                    (point))))
        (when (<= start (point) end)
          (let ((candidates (mapcar (lambda (entry)
                                      (propertize (substring (car entry) 1)
                                                  'kimi-code-ide-slash-command entry))
                                    kimi-code-ide-slash-commands)))
            (list start end candidates
                  :annotation-function
                  (lambda (cand)
                    (let* ((entry (get-text-property 0 'kimi-code-ide-slash-command cand))
                           (desc (plist-get (cdr entry) :desc)))
                      (format " — %s" desc)))
                  :company-kind (lambda (_) 'command))))))))

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

(defun kimi-code-ide--mode-line-indicator ()
  "Return a mode-line string showing stream status, or nil if idle."
  (when (and kimi-code-ide--stream-start-time
             (buffer-live-p (current-buffer)))
    (let* ((elapsed (float-time (time-subtract (current-time) kimi-code-ide--stream-start-time)))
           (tokens (max 1 kimi-code-ide--stream-token-count))
           (speed (/ tokens elapsed))
           (time-str (if (< elapsed 1)
                         "<1s"
                       (format "%.1fs" elapsed)))
           (tok-str (if (= 1 tokens)
                        "1 token"
                      (format "%d tokens" tokens)))
           (speed-str (format "%.1f tok/s" speed)))
      (propertize (format "Thinking %s · %s · %s" time-str tok-str speed-str)
                  'face 'mode-line-emphasis))))

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
       (setq kimi-code-ide--stream-start-time nil
             kimi-code-ide--stream-token-count 0
             kimi-code-ide--stream-chunk-count 0)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "* You\n")
       (kimi-code-ide--insert-read-only (kimi-code-ide--markdown-to-org data))
       (kimi-code-ide--insert-read-only "\n-----\n\n"))
      ('agent-text
       (let* ((text (if (consp data) (car data) data))
              (meta (if (consp data) (cdr data) nil))
              (usage-total (or (map-nested-elt meta '(usage totalTokens))
                               (map-nested-elt meta '(usage total_tokens)))))
         (unless kimi-code-ide--response-marker
           (goto-char (point-max))
           (kimi-code-ide--insert-read-only "* Kimi\n")
           (setq kimi-code-ide--response-marker (point-marker))
           (set-marker-insertion-type kimi-code-ide--response-marker t)
           (setq kimi-code-ide--response-raw-text ""
                 kimi-code-ide--stream-start-time (current-time)
                 kimi-code-ide--stream-token-count 0
                 kimi-code-ide--stream-chunk-count 0))
         (goto-char kimi-code-ide--response-marker)
         (setq kimi-code-ide--response-raw-text
               (concat kimi-code-ide--response-raw-text text))
         (kimi-code-ide--insert-read-only text)
         (cl-incf kimi-code-ide--stream-chunk-count)
         (if usage-total
             (setq kimi-code-ide--stream-token-count usage-total)
           (cl-incf kimi-code-ide--stream-token-count (max 1 (/ (length text) 4))))
         (force-mode-line-update)))
      ('tool-call
       (kimi-code-ide--flush-response-raw-text)
       (setq kimi-code-ide--stream-start-time nil
             kimi-code-ide--stream-token-count 0
             kimi-code-ide--stream-chunk-count 0)
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
       (setq kimi-code-ide--stream-start-time nil
             kimi-code-ide--stream-token-count 0
             kimi-code-ide--stream-chunk-count 0)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_QUOTE\n")
       (kimi-code-ide--insert-read-only "[Plan]\n")
       (dolist (entry data)
         (let-alist entry
           (kimi-code-ide--insert-read-only (format "- %s [%s]\n" .content .status))))
       (kimi-code-ide--insert-read-only "#+END_QUOTE\n\n"))
      ('diff
       (kimi-code-ide--flush-response-raw-text)
       (setq kimi-code-ide--stream-start-time nil
             kimi-code-ide--stream-token-count 0
             kimi-code-ide--stream-chunk-count 0)
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
       (let ((usage-total (map-nested-elt data '(total-tokens))))
         (when usage-total
           (setq kimi-code-ide--stream-token-count usage-total)))
       (setq kimi-code-ide--stream-start-time nil)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "\n\n")
       (force-mode-line-update))
      ('prompt-error
       (kimi-code-ide--flush-response-raw-text)
       (setq kimi-code-ide--stream-start-time nil
             kimi-code-ide--stream-token-count 0
             kimi-code-ide--stream-chunk-count 0)
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_CENTER\n")
       (kimi-code-ide--insert-read-only
        (format "[Error: %s]\n" (map-elt data 'message)))
       (kimi-code-ide--insert-read-only "#+END_CENTER\n\n")
       (force-mode-line-update))
      ('session-ready
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_CENTER\n")
       (kimi-code-ide--insert-read-only "[Session ready]\n")
       (kimi-code-ide--insert-read-only "#+END_CENTER\n\n"))
      ('session-resumed
       (goto-char (point-max))
       (kimi-code-ide--insert-read-only "#+BEGIN_CENTER\n")
       (kimi-code-ide--insert-read-only "[Session resumed]\n")
       (kimi-code-ide--insert-read-only "#+END_CENTER\n\n"))))
    ;; Keep window point at end if visible
    (when-let ((win (get-buffer-window (current-buffer))))
      (set-window-point win (point-max))))

;;; Mode Definitions

(defvar-keymap kimi-code-ide-input-mode-map
  :doc "Keymap for `kimi-code-ide-input-mode'."
  "C-c C-c" #'kimi-code-ide--submit-input-buffer
  "C-c C-p" #'kimi-code-ide-send-prompt
  "C-c C-q" #'kimi-code-ide-stop
  "M-TAB" #'completion-at-point)

(define-derived-mode kimi-code-ide-input-mode text-mode "Kimi Input"
  "Major mode for Kimi Code IDE input buffers."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type 'bar)
  ;; Slash command completion
  (add-hook 'completion-at-point-functions #'kimi-code-ide--slash-completion-at-point nil t)
  ;; Corfu configuration (graceful if not yet loaded)
  (when (boundp 'corfu-auto)
    (setq-local corfu-auto t)
    (setq-local corfu-auto-prefix 1))
  (when (boundp 'corfu-quit-at-boundary)
    (setq-local corfu-quit-at-boundary t))
  (when (boundp 'corfu-quit-no-match)
    (setq-local corfu-quit-no-match t))
  ;; Orderless configuration for this buffer
  (when (boundp 'completion-styles)
    (setq-local completion-styles
                (if (and (boundp 'completion-styles-alist)
                         (assoc 'orderless completion-styles-alist))
                    '(orderless basic)
                  '(basic))))
  (when (boundp 'completion-category-overrides)
    (setq-local completion-category-overrides '((file (styles . (partial-completion)))))))

(define-derived-mode kimi-code-ide-mode org-mode "Kimi Code"
  "Major mode for Kimi Code IDE conversation buffers."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type 'bar)
  (buffer-disable-undo)
  (when (boundp 'org-ctrl-k-protect-subtree)
    (setq-local org-ctrl-k-protect-subtree nil))
  ;; Append mode-line indicator
  (setq-local mode-line-format
              (append mode-line-format
                      '((:eval (kimi-code-ide--mode-line-indicator))))))

(defun kimi-code-ide--submit-input-buffer ()
  "Submit the contents of the current input buffer as a prompt.
If the buffer contains a known slash command, execute its associated
action instead of sending it to Kimi."
  (interactive)
  (unless kimi-code-ide--input-project-dir
    (user-error "Not in a Kimi Code input buffer"))
  (let ((input (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p input)
      (erase-buffer)
      (user-error "Empty prompt"))
    (let ((project-dir kimi-code-ide--input-project-dir)
          (command (assoc input kimi-code-ide-slash-commands)))
      (erase-buffer)
      (if command
          (let ((fn (plist-get (cdr command) :fn)))
            (kimi-code-ide-debug "Executing slash command: %s" input)
            (let ((default-directory project-dir))
              (if (eq fn 'kimi-code-ide-send-prompt)
                  (kimi-code-ide-send-prompt input)
                (call-interactively fn))))
        (let ((default-directory project-dir))
          (kimi-code-ide-send-prompt input))))))

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

(defun kimi-code-ide--cleanup-acp (directory)
  "Stop ACP and tools server for DIRECTORY without killing buffers."
  (kimi-code-ide-acp-stop directory)
  (let ((session-id (gethash directory kimi-code-ide--session-ids)))
    (when session-id
      (kimi-code-ide-tools-server-session-ended session-id)
      (remhash directory kimi-code-ide--session-ids)))
  (kimi-code-ide-debug "Cleaned up ACP for %s"
                       (file-name-nondirectory (directory-file-name directory))))

(defun kimi-code-ide--cleanup-on-exit (directory)
  "Clean up Kimi Code session when it exits for DIRECTORY."
  (unless kimi-code-ide--cleanup-in-progress
    (setq kimi-code-ide--cleanup-in-progress t)
    (unwind-protect
        (progn
          (kimi-code-ide--cleanup-acp directory)
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
          (kimi-code-ide-debug "Killed Kimi Code buffers for %s"
                               (file-name-nondirectory (directory-file-name directory))))
      (setq kimi-code-ide--cleanup-in-progress nil))))

(defun kimi-code-ide--start-session (&optional resume)
  "Start a Kimi Code ACP session for the current project.
When RESUME is non-nil and an existing conversation buffer is
available, reuse it without erasing history."
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
      (let* ((buffer (if (and resume existing-buffer (buffer-live-p existing-buffer))
                         existing-buffer
                       (kimi-code-ide--ensure-buffer working-dir)))
             (render-fn (kimi-code-ide--render-function working-dir))
             (resuming-p (and resume existing-buffer (buffer-live-p existing-buffer)
                              (not (and session (kimi-code-ide-acp-session-initialized session))))))
        (kimi-code-ide-acp--set-render-function working-dir render-fn)
        (kimi-code-ide--display-buffer-in-side-window buffer)
        (kimi-code-ide-acp-start
         buffer working-dir
         (lambda (session-id)
           (kimi-code-ide--render-in-buffer
            (if resuming-p 'session-resumed 'session-ready) session-id)
           (kimi-code-ide-log "Kimi Code %s in %s (session: %s)"
                              (if resuming-p "resumed" "started")
                              (file-name-nondirectory (directory-file-name working-dir))
                              session-id)))))))

;;;###autoload
(defun kimi-code-ide ()
  "Run Kimi Code for the current project or directory."
  (interactive)
  (kimi-code-ide--start-session))

(defun kimi-code-ide--render-history-turns-into-buffer (buffer turns)
  "Render TURNS into BUFFER as org-mode headings."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (dolist (turn turns)
        (let ((user-text (car turn))
              (assistant-text (cdr turn)))
          (when (> (length user-text) 0)
            (kimi-code-ide--insert-read-only "* You\n")
            (kimi-code-ide--insert-read-only (kimi-code-ide--markdown-to-org user-text))
            (kimi-code-ide--insert-read-only "\n-----\n\n"))
          (when (> (length assistant-text) 0)
            (kimi-code-ide--insert-read-only "* Kimi\n")
            (kimi-code-ide--insert-read-only (kimi-code-ide--markdown-to-org assistant-text))
            (kimi-code-ide--insert-read-only "\n\n")))))))

(defun kimi-code-ide--buffer-has-history-p ()
  "Return non-nil if the current buffer already contains conversation turns."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\\* You\\(?:[ \t]\\|$\\)" nil t)))

;;;###autoload
(defun kimi-code-ide-resume ()
  "Resume the Kimi Code conversation for the current project."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name working-dir))
         (buffer (get-buffer buffer-name))
         (disk-turns (kimi-code-ide--read-kimi-session-turns working-dir))
         (session (kimi-code-ide-acp--get-session-for-project working-dir))
         (session-active (and session (kimi-code-ide-acp-session-initialized session))))
    ;; Ensure disk history is visible in the buffer if it lacks conversation turns
    (when disk-turns
      (unless (and buffer (buffer-live-p buffer))
        (setq buffer (get-buffer-create buffer-name))
        (with-current-buffer buffer
          (kimi-code-ide-mode)
          (setq kimi-code-ide--project-dir working-dir)
          (add-hook 'kill-buffer-hook
                    (lambda ()
                      (kimi-code-ide--cleanup-on-exit working-dir))
                    nil t)))
      (with-current-buffer buffer
        (unless (kimi-code-ide--buffer-has-history-p)
          (kimi-code-ide--render-history-turns-into-buffer buffer disk-turns))))
    ;; Only queue pending history when the session is NOT already active
    (unless session-active
      (let ((history-string (or (kimi-code-ide--format-session-turns disk-turns)
                                (and buffer (buffer-live-p buffer)
                                     (kimi-code-ide--extract-conversation-history buffer)))))
        (when history-string
          (puthash working-dir history-string kimi-code-ide--pending-resume-history))))
    (if session-active
        (when (and buffer (buffer-live-p buffer))
          (kimi-code-ide--display-buffer-in-side-window buffer))
      (kimi-code-ide--start-session t))))

;;;###autoload
(defun kimi-code-ide-stop ()
  "Stop the Kimi Code ACP session for the current project.
The conversation buffer is kept so you can resume later with
`kimi-code-ide-resume'."
  (interactive)
  (let ((working-dir (kimi-code-ide--get-working-directory)))
    (kimi-code-ide--cleanup-acp working-dir)
    (kimi-code-ide-log "Stopped Kimi Code in %s (buffer kept for resume)"
                       (file-name-nondirectory (directory-file-name working-dir)))))

;;;###autoload
(defun kimi-code-ide-kill ()
  "Stop the Kimi Code session and kill its buffers."
  (interactive)
  (let* ((working-dir (kimi-code-ide--get-working-directory))
         (buffer-name (kimi-code-ide--get-buffer-name))
         (input-buffer-name (kimi-code-ide--get-input-buffer-name working-dir)))
    (kimi-code-ide--cleanup-acp working-dir)
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
    (kimi-code-ide-log "Killed Kimi Code session in %s"
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
    (let* ((display-prompt (or prompt (read-string "Kimi prompt: ")))
           (prompt-to-send display-prompt))
      (when (not (string-empty-p display-prompt))
        (let ((pending (gethash working-dir kimi-code-ide--pending-resume-history)))
          (when pending
            (setq prompt-to-send (concat pending display-prompt))
            (remhash working-dir kimi-code-ide--pending-resume-history)))
        (with-current-buffer buffer
          (kimi-code-ide--render-in-buffer 'user-prompt display-prompt))
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
