;;; kimi-code-ide-acp.el --- ACP integration for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, acp

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

;; This file implements the ACP (Agent Client Protocol) integration
;; layer for Kimi Code IDE.  It wraps `acp.el' to manage the connection
;; to `kimi acp', handles session lifecycle, and routes agent
;; notifications and requests.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'map)
(require 'acp)
(require 'kimi-code-ide-debug)

;; Declare variables from other files
(defvar kimi-code-ide--session-ids)
(defvar kimi-code-ide-cli-path)
(defvar kimi-code-ide-system-prompt)

;; Declare functions from acp.el
(declare-function acp--client-started-p "acp" (client))
(declare-function acp--start-client "acp" (&rest args))
(declare-function acp-subscribe-to-errors "acp" (&rest args))
(declare-function acp-make-session-prompt-request "acp" (&rest args))
(declare-function acp-make-session-cancel-notification "acp" (&rest args))
(declare-function acp-make-error "acp" (&rest args))
(declare-function acp-make-fs-read-text-file-response "acp" (&rest args))
(declare-function acp-make-fs-write-text-file-response "acp" (&rest args))

;; Terminal backend declarations
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-mode "vterm" ())
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile &rest switches))
(declare-function kimi-code-ide--cleanup-on-exit "kimi-code-ide" (directory))

(defvar vterm-shell)
(defvar kimi-code-ide-terminal-backend)
(defvar kimi-code-ide-cli-path)
(declare-function kimi-code-ide--get-working-directory "kimi-code-ide" ())
(declare-function kimi-code-ide--get-buffer-name "kimi-code-ide" (&optional directory))
(declare-function kimi-code-ide-tools-server-get-config "kimi-code-ide-tools-server" (&optional session-id))
(declare-function kimi-code-ide-tools-server-ensure-server "kimi-code-ide-tools-server" ())

;;; Session State

(defvar kimi-code-ide-acp--sessions (make-hash-table :test 'equal)
  "Hash table mapping project directories to ACP session state.")

(cl-defstruct kimi-code-ide-acp-session
  "Structure to hold ACP session state."
  client           ; ACP client object
  project-dir      ; Project directory
  buffer           ; Display buffer
  session-id       ; ACP session ID
  initialized      ; Whether initialize handshake completed
  prompt-in-progress ; Whether a prompt turn is active
  pending-permissions) ; Hash table of pending permission requests

(defun kimi-code-ide-acp--get-session-for-project (project-dir)
  "Get the ACP session for PROJECT-DIR."
  (when project-dir
    (gethash project-dir kimi-code-ide-acp--sessions)))

(defun kimi-code-ide-acp--get-current-session ()
  "Get the ACP session for the current buffer's project."
  (when-let ((project-dir (kimi-code-ide--get-working-directory)))
    (kimi-code-ide-acp--get-session-for-project project-dir)))

;;; ACP Client Lifecycle

(defun kimi-code-ide-acp--make-client (buffer _working-dir)
  "Create an ACP client for BUFFER in WORKING-DIR."
  (let* ((cmd kimi-code-ide-cli-path)
         (params '("acp"))
         (client (acp-make-client :command cmd
                                  :command-params params
                                  :context-buffer buffer)))
    client))

(defun kimi-code-ide-acp--start-client (client)
  "Start the ACP CLIENT subprocess if not already started."
  (unless (acp--client-started-p client)
    (acp--start-client :client client)))

(defun kimi-code-ide-acp--subscribe (client buffer project-dir)
  "Subscribe CLIENT to ACP events, routing to BUFFER and PROJECT-DIR."
  (acp-subscribe-to-notifications
   :client client
   :buffer buffer
   :on-notification (lambda (notification)
                      (kimi-code-ide-acp--handle-notification
                       notification project-dir)))
  (acp-subscribe-to-requests
   :client client
   :buffer buffer
   :on-request (lambda (request)
                 (kimi-code-ide-acp--handle-request
                  request project-dir)))
  (acp-subscribe-to-errors
   :client client
   :buffer buffer
   :on-error (lambda (error)
               (kimi-code-ide-debug "ACP error: %S" error)
               (message "Kimi ACP error: %s" (map-elt error 'message))
               (when (string-match-p "\\(disconnect\\|connection\\|process\\|exited\\|closed\\)"
                                     (or (map-elt error 'message) ""))
                 (kimi-code-ide-debug "ACP fatal error detected, cleaning up session")
                 (kimi-code-ide--cleanup-on-exit project-dir)))))

;;; Handshake and Session Init

(defun kimi-code-ide-acp--initialize (project-dir &optional on-success)
  "Send ACP initialize request for PROJECT-DIR.
Call ON-SUCCESS when initialization completes successfully."
  (when-let ((session (kimi-code-ide-acp--get-session-for-project project-dir)))
    (let ((client (kimi-code-ide-acp-session-client session))
          (buffer (kimi-code-ide-acp-session-buffer session)))
      (acp-send-request
       :client client
       :buffer buffer
       :request (acp-make-initialize-request
                 :protocol-version 1
                 :client-info '((name . "kimi-code-ide")
                                (title . "Kimi Code IDE for Emacs")
                                (version . "0.1.0"))
                 :read-text-file-capability t
                 :write-text-file-capability t)
       :on-success (lambda (response)
                     (kimi-code-ide-debug "ACP initialized: %S" response)
                     (setf (kimi-code-ide-acp-session-initialized session) t)
                     (when on-success
                       (funcall on-success)))
       :on-failure (lambda (error)
                     (kimi-code-ide-debug "ACP initialize failed: %S" error)
                     (message "Kimi ACP initialization failed: %s"
                              (map-elt error 'message)))))))

(defun kimi-code-ide-acp--start-session (project-dir &optional on-success)
  "Send ACP session/new request for PROJECT-DIR.
Call ON-SUCCESS with the session-id when session creation completes."
  (when-let ((session (kimi-code-ide-acp--get-session-for-project project-dir)))
    (let ((client (kimi-code-ide-acp-session-client session))
          (buffer (kimi-code-ide-acp-session-buffer session))
          (mcp-servers nil))
      ;; Add MCP tools server config if enabled
      (when (kimi-code-ide-tools-server-ensure-server)
        (when-let ((config (kimi-code-ide-tools-server-get-config)))
          (setq mcp-servers (vector config))))
      (acp-send-request
       :client client
       :buffer buffer
       :request (acp-make-session-new-request
                 :cwd project-dir
                 :mcp-servers mcp-servers
                 :meta (when kimi-code-ide-system-prompt
                         `((systemPrompt . ((append . ,kimi-code-ide-system-prompt))))))
       :on-success (lambda (response)
                     (let-alist response
                       (let ((session-id .sessionId))
                         (setf (kimi-code-ide-acp-session-session-id session) session-id)
                         (puthash project-dir session-id kimi-code-ide--session-ids)
                         (kimi-code-ide-debug "ACP session created: %s" session-id)
                         (when on-success
                           (funcall on-success session-id)))))
       :on-failure (lambda (error)
                     (kimi-code-ide-debug "ACP session/new failed: %S" error)
                     (message "Kimi ACP session creation failed: %s"
                              (map-elt error 'message)))))))

;;; Prompt Sending

(defun kimi-code-ide-acp--send-prompt (project-dir prompt-text &optional on-complete)
  "Send PROMPT-TEXT to the agent for PROJECT-DIR.
Call ON-COMPLETE when the prompt turn finishes."
  (when-let ((session (kimi-code-ide-acp--get-session-for-project project-dir)))
    (let ((session-id (kimi-code-ide-acp-session-session-id session))
          (client (kimi-code-ide-acp-session-client session))
          (buffer (kimi-code-ide-acp-session-buffer session)))
      (unless session-id
        (user-error "Kimi ACP session not ready"))
      (setf (kimi-code-ide-acp-session-prompt-in-progress session) t)
      (kimi-code-ide-debug "Sending prompt: %s" prompt-text)
      (acp-send-request
       :client client
       :buffer buffer
       :request (acp-make-session-prompt-request
                 :session-id session-id
                 :prompt (vector `((type . "text")
                                   (text . ,prompt-text))))
       :on-success (lambda (response)
                     (setf (kimi-code-ide-acp-session-prompt-in-progress session) nil)
                     (kimi-code-ide-debug "Prompt response: %S" response)
                     (kimi-code-ide-acp--render-prompt-complete project-dir response)
                     (when on-complete
                       (funcall on-complete response)))
       :on-failure (lambda (error)
                     (setf (kimi-code-ide-acp-session-prompt-in-progress session) nil)
                     (kimi-code-ide-debug "Prompt failed: %S" error)
                     (kimi-code-ide-acp--render-prompt-error project-dir error)
                     (when on-complete
                       (funcall on-complete error)))))))

(defun kimi-code-ide-acp--cancel-prompt (project-dir)
  "Cancel the current prompt turn for PROJECT-DIR."
  (when-let ((session (kimi-code-ide-acp--get-session-for-project project-dir)))
    (let ((session-id (kimi-code-ide-acp-session-session-id session))
          (client (kimi-code-ide-acp-session-client session))
          (_buffer (kimi-code-ide-acp-session-buffer session)))
      (when session-id
        (acp-send-notification
         :client client
         :notification (acp-make-session-cancel-notification
                        :session-id session-id)
         :sync nil)
        (setf (kimi-code-ide-acp-session-prompt-in-progress session) nil)
        (kimi-code-ide-debug "Prompt cancelled for session %s" session-id)))))

;;; Notification Handling

(defun kimi-code-ide-acp--handle-notification (notification project-dir)
  "Handle an incoming ACP NOTIFICATION for PROJECT-DIR."
  (let-alist notification
    (pcase .method
      ("session/update"
       (kimi-code-ide-acp--handle-session-update .params project-dir))
      (_
       (kimi-code-ide-debug "Unhandled notification: %s" .method)))))

(defun kimi-code-ide-acp--handle-session-update (params project-dir)
  "Handle a session/update notification with PARAMS for PROJECT-DIR."
  (let-alist params
    (let ((update .update))
      (let-alist update
        (pcase .sessionUpdate
          ("agent_message_chunk"
           (when-let ((text (map-nested-elt update '(content text))))
             (kimi-code-ide-acp--render-agent-text project-dir text)))
          ("tool_call"
           (kimi-code-ide-acp--render-tool-call project-dir update))
          ("plan"
           (kimi-code-ide-acp--render-plan project-dir .entries))
          ("diff"
           (let* ((path (map-nested-elt update '(path)))
                  (old-text (map-nested-elt update '(oldText)))
                  (new-text (map-nested-elt update '(newText))))
             (when (and path new-text)
               (kimi-code-ide-acp--render
                project-dir 'diff
                `((path . ,path)
                  (old-text . ,old-text)
                  (new-text . ,new-text))))))
          (_
           (kimi-code-ide-debug "Unhandled session/update: %s" .sessionUpdate)))))))

(defun kimi-code-ide-acp--handle-request (request project-dir)
  "Handle an incoming ACP REQUEST for PROJECT-DIR."
  (let-alist request
    (pcase .method
      ("fs/read_text_file"
       (kimi-code-ide-acp--handle-fs-read-text-file request project-dir))
      ("fs/write_text_file"
       (kimi-code-ide-acp--handle-fs-write-text-file request project-dir))
      ("terminal/create"
       (kimi-code-ide-acp--handle-terminal-create request project-dir))
      ("terminal/output"
       (kimi-code-ide-acp--handle-terminal-output request project-dir))
      ("terminal/wait_for_exit"
       (kimi-code-ide-acp--handle-terminal-wait-for-exit request project-dir))
      ("terminal/release"
       (kimi-code-ide-acp--handle-terminal-release request project-dir))
      ("terminal/kill"
       (kimi-code-ide-acp--handle-terminal-kill request project-dir))
      ("session/request_permission"
       (kimi-code-ide-acp--handle-request-permission request project-dir))
      (_
       (kimi-code-ide-debug "Unhandled request: %s" .method)
       (acp-send-response
        :client (kimi-code-ide-acp-session-client
                 (kimi-code-ide-acp--get-session-for-project project-dir))
        :response (acp-make-error
                   :code -32601
                   :message (format "Method not found: %s" .method)))))))

;;; Rendering (to be refined by UI layer)

(defvar kimi-code-ide-acp--render-functions nil
  "Alist of PROJECT-DIR to rendering function.")

(defun kimi-code-ide-acp--set-render-function (project-dir render-fn)
  "Set RENDER-FN as the rendering function for PROJECT-DIR."
  (unless kimi-code-ide-acp--render-functions
    (setq kimi-code-ide-acp--render-functions (make-hash-table :test 'equal)))
  (puthash project-dir render-fn kimi-code-ide-acp--render-functions))

(defun kimi-code-ide-acp--render (project-dir type data)
  "Render DATA of TYPE for PROJECT-DIR using the registered render function."
  (when-let ((render-fn (gethash project-dir kimi-code-ide-acp--render-functions)))
    (funcall render-fn type data)))

(defun kimi-code-ide-acp--render-agent-text (project-dir text)
  "Render agent TEXT for PROJECT-DIR."
  (kimi-code-ide-acp--render project-dir 'agent-text text))

(defun kimi-code-ide-acp--render-tool-call (project-dir tool-call)
  "Render TOOL-CALL for PROJECT-DIR."
  (kimi-code-ide-acp--render project-dir 'tool-call tool-call))

(defun kimi-code-ide-acp--render-plan (project-dir entries)
  "Render plan ENTRIES for PROJECT-DIR."
  (kimi-code-ide-acp--render project-dir 'plan entries))

(defun kimi-code-ide-acp--render-prompt-complete (project-dir response)
  "Render prompt completion for PROJECT-DIR with RESPONSE."
  (kimi-code-ide-acp--render project-dir 'prompt-complete response))

(defun kimi-code-ide-acp--render-prompt-error (project-dir error)
  "Render prompt ERROR for PROJECT-DIR."
  (kimi-code-ide-acp--render project-dir 'prompt-error error))

;;; Client Method Handlers

(defun kimi-code-ide-acp--handle-fs-read-text-file (request project-dir)
  "Handle fs/read_text_file REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((path (map-nested-elt .params '(path)))
           (line (map-nested-elt .params '(line)))
           (limit (map-nested-elt .params '(limit)))
           (client (kimi-code-ide-acp-session-client
                    (kimi-code-ide-acp--get-session-for-project project-dir)))
           (content nil)
           (error-obj nil))
      (condition-case err
          (if (and path (file-exists-p path))
              (setq content (with-temp-buffer
                              (insert-file-contents path)
                              (when line
                                (goto-char (point-min))
                                (forward-line (1- line)))
                              (let ((start (point)))
                                (when limit
                                  (forward-line limit))
                                (buffer-substring start (point)))))
            (setq error-obj (acp-make-error
                             :code -32001
                             :message (format "File not found: %s" path))))
        (error
         (setq error-obj (acp-make-error
                          :code -32603
                          :message (format "Failed to read file: %s"
                                           (error-message-string err))))))
      (acp-send-response
       :client client
       :response (if error-obj
                     `((:request-id . ,.id)
                       (:error . ,error-obj))
                   (acp-make-fs-read-text-file-response
                    :request-id .id
                    :content content))))))

(defun kimi-code-ide-acp--handle-fs-write-text-file (request project-dir)
  "Handle fs/write_text_file REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((path (map-nested-elt .params '(path)))
           (content (map-nested-elt .params '(content)))
           (client (kimi-code-ide-acp-session-client
                    (kimi-code-ide-acp--get-session-for-project project-dir)))
           (error-obj nil))
      (condition-case err
          (when path
            (with-temp-file path
              (insert content)))
        (error
         (setq error-obj (acp-make-error
                          :code -32603
                          :message (format "Failed to write file: %s"
                                           (error-message-string err))))))
      (acp-send-response
       :client client
       :response (if error-obj
                     `((:request-id . ,.id)
                       (:error . ,error-obj))
                   (acp-make-fs-write-text-file-response
                    :request-id .id))))))

(defvar kimi-code-ide-acp--terminals (make-hash-table :test 'equal)
  "Hash table mapping terminal IDs to process objects.")

(defun kimi-code-ide-acp--handle-terminal-create (request project-dir)
  "Handle terminal/create REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((session (kimi-code-ide-acp--get-session-for-project project-dir))
           (client (kimi-code-ide-acp-session-client session))
           (command (map-nested-elt .params '(command)))
           (args (map-nested-elt .params '(args)))
           (cwd (map-nested-elt .params '(cwd)))
           (env (map-nested-elt .params '(env)))
           (terminal-id (format "kimi-term-%s" (random 1000000)))
           (backend (when (boundp 'kimi-code-ide-terminal-backend)
                      kimi-code-ide-terminal-backend))
           (proc nil)
           (term-buffer nil))
      (condition-case err
          (let* ((default-directory (or cwd default-directory))
                 (process-environment (append
                                      (mapcar (lambda (var)
                                                (format "%s=%s" (map-elt var 'name)
                                                        (map-elt var 'value)))
                                              env)
                                      process-environment)))
            (cond
             ;; vterm backend
             ((and (eq backend 'vterm) (fboundp 'vterm))
              (let* ((vterm-buffer-name (format "*%s*" terminal-id))
                     (vterm-shell (mapconcat #'shell-quote-argument
                                             (append (list command) args)
                                             " ")))
                (setq term-buffer (save-window-excursion
                                    (vterm vterm-buffer-name)))
                (unless term-buffer
                  (error "Failed to create vterm buffer"))
                (setq proc (get-buffer-process term-buffer))
                (unless proc
                  (error "Failed to get vterm process"))))
             ;; eat backend
             ((and (eq backend 'eat) (fboundp 'eat-mode))
              (setq term-buffer (get-buffer-create (format "*%s*" terminal-id)))
              (with-current-buffer term-buffer
                (unless (eq major-mode 'eat-mode)
                  (eat-mode))
                (setq-local eat-kill-buffer-on-exit t))
              (eat-exec term-buffer terminal-id command nil args)
              (setq proc (get-buffer-process term-buffer))
              (unless proc
                (error "Failed to get eat process")))
             ;; Plain process fallback
             (t
              (setq proc (make-process
                          :name terminal-id
                          :command (append (list command) args)
                          :buffer (get-buffer-create (format "*%s*" terminal-id))
                          :noquery t)))))
        (error
         (acp-send-response
          :client client
          :response (acp-make-error
                     :code -32603
                     :message (format "Failed to create terminal: %s"
                                      (error-message-string err))))))
      (when proc
        (puthash terminal-id proc kimi-code-ide-acp--terminals)
        (acp-send-response
         :client client
         :response `((:request-id . ,.id)
                     (:result . ((terminalId . ,terminal-id)))))))))

(defun kimi-code-ide-acp--handle-terminal-output (_request _project-dir)
  "Handle terminal/output REQUEST.
TODO: implement output retrieval."
  ;; Placeholder - would need to track process output
  )

(defun kimi-code-ide-acp--handle-terminal-wait-for-exit (_request _project-dir)
  "Handle terminal/wait_for_exit REQUEST.
TODO: implement exit status retrieval."
  ;; Placeholder
  )

(defun kimi-code-ide-acp--handle-terminal-release (request project-dir)
  "Handle terminal/release REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((terminal-id (map-nested-elt .params '(terminalId)))
           (client (kimi-code-ide-acp-session-client
                    (kimi-code-ide-acp--get-session-for-project project-dir)))
           (proc (gethash terminal-id kimi-code-ide-acp--terminals)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (remhash terminal-id kimi-code-ide-acp--terminals)
      (acp-send-response
       :client client
       :response `((:request-id . ,.id)
                   (:result . nil))))))

(defun kimi-code-ide-acp--handle-terminal-kill (request project-dir)
  "Handle terminal/kill REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((terminal-id (map-nested-elt .params '(terminalId)))
           (client (kimi-code-ide-acp-session-client
                    (kimi-code-ide-acp--get-session-for-project project-dir)))
           (proc (gethash terminal-id kimi-code-ide-acp--terminals)))
      (when (and proc (process-live-p proc))
        (signal-process proc 'SIGKILL))
      (acp-send-response
       :client client
       :response `((:request-id . ,.id)
                   (:result . nil))))))

(defun kimi-code-ide-acp--handle-request-permission (request project-dir)
  "Handle session/request_permission REQUEST for PROJECT-DIR."
  (let-alist request
    (let* ((session (kimi-code-ide-acp--get-session-for-project project-dir))
           (client (kimi-code-ide-acp-session-client session))
           (options (map-nested-elt .params '(options)))
           (tool-call (map-nested-elt .params '(toolCall)))
           (tool-call-id (map-nested-elt tool-call '(toolCallId)))
           (option-names (mapcar (lambda (opt)
                                   (cons (map-elt opt 'name)
                                         (map-elt opt 'optionId)))
                                 options))
           (choice (completing-read
                    (format "Kimi requests permission for %s: "
                            (or tool-call-id "tool call"))
                    option-names nil t)))
      (acp-send-response
       :client client
       :response (acp-make-session-request-permission-response
                  :request-id .id
                  :option-id (cdr (assoc choice option-names)))))))

;;; Public API

(defun kimi-code-ide-acp-start (buffer project-dir &optional on-ready)
  "Start the ACP client for PROJECT-DIR, displaying in BUFFER.
Call ON-READY with the session-id when the session is ready for prompts."
  (kimi-code-ide-debug "Starting ACP for %s" project-dir)
  (let* ((client (kimi-code-ide-acp--make-client buffer project-dir))
         (session (make-kimi-code-ide-acp-session
                   :client client
                   :project-dir project-dir
                   :buffer buffer
                   :pending-permissions (make-hash-table :test 'equal))))
    (puthash project-dir session kimi-code-ide-acp--sessions)
    (kimi-code-ide-acp--start-client client)
    (when-let ((process (map-elt client :process)))
      (set-process-sentinel
       process
       (lambda (_proc event)
         (kimi-code-ide-debug "ACP process event: %s" event)
         (when (or (string-match-p "finished\\|exited\\|killed\\|terminated" event)
                   (string-match-p "exited abnormally" event))
           (message "Kimi ACP process ended (%s)" event)
           (kimi-code-ide--cleanup-on-exit project-dir)))))
    (kimi-code-ide-acp--subscribe client buffer project-dir)
    ;; Initialize -> start session
    (kimi-code-ide-acp--initialize
     project-dir
     (lambda ()
       (kimi-code-ide-acp--start-session
        project-dir
        (lambda (session-id)
          (when on-ready
            (funcall on-ready session-id))))))
    session))

(defun kimi-code-ide-acp-stop (project-dir)
  "Stop the ACP session for PROJECT-DIR."
  (when-let ((session (gethash project-dir kimi-code-ide-acp--sessions)))
    (when-let ((client (kimi-code-ide-acp-session-client session)))
      (condition-case err
          (acp-shutdown :client client)
        (error (kimi-code-ide-debug "Error shutting down ACP client: %s" err))))
    (remhash project-dir kimi-code-ide-acp--sessions)))

(provide 'kimi-code-ide-acp)

;;; kimi-code-ide-acp.el ends here
