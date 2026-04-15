;;; kimi-code-ide-tools-server.el --- MCP tools server for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, tools, mcp

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

;; This module provides an MCP tools server that exposes Emacs functions
;; to Kimi Code.  Unlike the IDE ACP server (which uses stdio), this
;; uses HTTP/Streamable HTTP transport and provides access to general
;; Emacs functionality like xref, project navigation, etc.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'kimi-code-ide-debug)

;; Forward declarations
(declare-function ws-process "web-server" (server))
(declare-function kimi-code-ide-tools-http-server-start "kimi-code-ide-tools-http" (handler &optional port))
(declare-function kimi-code-ide-tools-http-server-stop "kimi-code-ide-tools-http" (server))

;;; Customization

(defgroup kimi-code-ide-tools-server nil
  "MCP tools server settings for Kimi Code IDE."
  :group 'kimi-code-ide
  :prefix "kimi-code-ide-tools-server-")

(defcustom kimi-code-ide-enable-tools-server nil
  "Enable MCP tools server for exposing Emacs functions to Kimi.
When enabled, a separate MCP server will be started to provide
Kimi with access to configured Emacs functions."
  :type 'boolean
  :group 'kimi-code-ide-tools-server)

(defcustom kimi-code-ide-tools-server-port nil
  "Port for the MCP tools server.
If nil, a random available port will be selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'kimi-code-ide-tools-server)

(defcustom kimi-code-ide-tools-server-tools nil
  "Alist of Emacs functions to expose via MCP tools server.
Each entry is (FUNCTION . PLIST) where PLIST contains:
  :description - Human-readable description of the function
  :parameters - List of parameter specifications, each with:
    :name - Parameter name
    :type - Parameter type (string, number, boolean)
    :required - Whether parameter is required
    :description - Parameter description"
  :type '(alist :key-type symbol
                :value-type (plist :key-type keyword
                                   :value-type sexp))
  :group 'kimi-code-ide-tools-server)

;;; State Management

(defvar kimi-code-ide-tools-server--server nil
  "The MCP tools server process.")

(defvar kimi-code-ide-tools-server--port nil
  "The port the MCP tools server is running on.")

(defvar kimi-code-ide-tools-server--session-count 0
  "Number of active Kimi sessions using the MCP tools server.")

(defvar kimi-code-ide-tools-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.")

(defvar kimi-code-ide-tools-server--current-session-id nil
  "The session ID for the current MCP tool request.")

;;; Tool Definition Functions

(defun kimi-code-ide-tools-server-make-tool (&rest slots)
  "Make a Kimi Code IDE tool for MCP use.
Keyword arguments:
:FUNCTION - The Emacs function to call.
:NAME - The name of the tool.
:DESCRIPTION - Human-readable description.
:ARGS - A list of plists specifying arguments, or nil.
:CATEGORY - A string indicating a category for the tool (optional)."
  (let ((function (plist-get slots :function))
        (name (plist-get slots :name))
        (description (plist-get slots :description))
        (args (plist-get slots :args))
        (category (plist-get slots :category)))
    (unless function
      (error "Tool :function is required"))
    (unless name
      (error "Tool :name is required"))
    (unless description
      (error "Tool :description is required"))
    (let ((spec (list :function function
                      :name name
                      :description description)))
      (when args
        (setq spec (plist-put spec :args args)))
      (when category
        (setq spec (plist-put spec :category category)))
      (add-to-list 'kimi-code-ide-tools-server-tools spec)
      spec)))

;;; Format Detection and Conversion

(defun kimi-code-ide-tools-server--tool-format-p (tool-spec)
  "Determine format of TOOL-SPEC.
Returns \='old for (symbol . plist) format, \='new for plist format."
  (cond
   ((and (consp tool-spec)
         (symbolp (car tool-spec))
         (not (keywordp (car tool-spec))))
    'old)
   ((and (listp tool-spec)
         (keywordp (car tool-spec)))
    'new)
   (t
    (error "Unknown tool format: %S" tool-spec))))

(defun kimi-code-ide-tools-server--normalize-tool-spec (tool-spec)
  "Convert TOOL-SPEC to normalized format for processing."
  (let ((format (kimi-code-ide-tools-server--tool-format-p tool-spec)))
    (cond
     ((eq format 'old)
      (let* ((func (car tool-spec))
             (plist (cdr tool-spec))
             (description (plist-get plist :description))
             (parameters (plist-get plist :parameters)))
        (message "Warning: Tool '%s' is using deprecated format."
                 (symbol-name func))
        (list :function func
              :name (symbol-name func)
              :description description
              :args (kimi-code-ide-tools-server--parameters-to-args parameters))))
     ((eq format 'new)
      tool-spec)
     (t
      (error "Cannot normalize tool spec: %S" tool-spec)))))

(defun kimi-code-ide-tools-server--parameters-to-args (parameters)
  "Convert PARAMETERS (old format) to :args (new format)."
  (mapcar (lambda (param)
            (let ((name (plist-get param :name))
                  (type (plist-get param :type))
                  (description (plist-get param :description))
                  (required (plist-get param :required)))
              (let ((arg (list :name name
                               :type (if (stringp type)
                                         (intern type)
                                       type))))
                (when description
                  (setq arg (plist-put arg :description description)))
                (unless required
                  (setq arg (plist-put arg :optional t)))
                (when-let ((enum (plist-get param :enum)))
                  (setq arg (plist-put arg :enum enum)))
                (when-let ((items (plist-get param :items)))
                  (setq arg (plist-put arg :items items)))
                (when-let ((properties (plist-get param :properties)))
                  (setq arg (plist-put arg :properties properties)))
                arg)))
          parameters))

;;; Public Functions

(defun kimi-code-ide-tools-server-ensure-server ()
  "Ensure the MCP tools server is running.
Returns the port number on success, nil on failure."
  (when kimi-code-ide-enable-tools-server
    (unless (and kimi-code-ide-tools-server--server
                 kimi-code-ide-tools-server--port
                 (kimi-code-ide-tools-server--server-alive-p))
      (kimi-code-ide-tools-server--start-server))
    kimi-code-ide-tools-server--port))

(defun kimi-code-ide-tools-server-get-port ()
  "Get the port number of the running MCP tools server."
  (when (and kimi-code-ide-tools-server--server
             kimi-code-ide-tools-server--port
             (kimi-code-ide-tools-server--server-alive-p))
    kimi-code-ide-tools-server--port))

(defun kimi-code-ide-tools-server-session-started (&optional session-id project-dir buffer)
  "Notify that a Kimi session has started."
  (cl-incf kimi-code-ide-tools-server--session-count)
  (kimi-code-ide-debug "MCP session started. Count: %d"
                       kimi-code-ide-tools-server--session-count)
  (when (and session-id project-dir buffer)
    (kimi-code-ide-tools-server-register-session session-id project-dir buffer)))

(defun kimi-code-ide-tools-server-session-ended (&optional session-id)
  "Notify that a Kimi session has ended."
  (when session-id
    (kimi-code-ide-tools-server-unregister-session session-id))
  (when (> kimi-code-ide-tools-server--session-count 0)
    (cl-decf kimi-code-ide-tools-server--session-count)
    (kimi-code-ide-debug "MCP session ended. Count: %d"
                         kimi-code-ide-tools-server--session-count)
    (when (= kimi-code-ide-tools-server--session-count 0)
      (kimi-code-ide-tools-server--stop-server))))

(defun kimi-code-ide-tools-server-get-config (&optional session-id)
  "Get the MCP configuration for the tools server."
  (when-let ((port (kimi-code-ide-tools-server-get-port)))
    (let* ((path (if session-id
                     (format "/mcp/%s" session-id)
                   "/mcp"))
           (url (format "http://localhost:%d%s" port path))
           (config `((type . "http")
                     (url . ,url))))
      `((mcpServers . ((emacs-tools . ,config)))))))

(defun kimi-code-ide-tools-server-get-tool-names (&optional prefix)
  "Get a list of all registered MCP tool names."
  (mapcar (lambda (tool-spec)
            (let* ((normalized (kimi-code-ide-tools-server--normalize-tool-spec tool-spec))
                   (tool-name (or (plist-get normalized :name)
                                  (symbol-name (plist-get normalized :function)))))
              (if prefix
                  (concat prefix tool-name)
                tool-name)))
          kimi-code-ide-tools-server-tools))

;;; Session Management Functions

(defun kimi-code-ide-tools-server-register-session (session-id project-dir buffer)
  "Register a new session with SESSION-ID, PROJECT-DIR, and BUFFER."
  (puthash session-id
           (list :project-dir project-dir
                 :buffer buffer
                 :last-active-buffer nil
                 :start-time (current-time))
           kimi-code-ide-tools-server--sessions)
  (kimi-code-ide-debug "Registered MCP session %s for project %s" session-id project-dir))

(defun kimi-code-ide-tools-server-unregister-session (session-id)
  "Unregister the session with SESSION-ID."
  (when (gethash session-id kimi-code-ide-tools-server--sessions)
    (remhash session-id kimi-code-ide-tools-server--sessions)
    (kimi-code-ide-debug "Unregistered MCP session %s" session-id)))

(defun kimi-code-ide-tools-server-get-session-context (&optional session-id)
  "Get the context for SESSION-ID or the current session."
  (let ((id (or session-id kimi-code-ide-tools-server--current-session-id)))
    (when id
      (gethash id kimi-code-ide-tools-server--sessions))))

(defun kimi-code-ide-tools-server-update-last-active-buffer (session-id buffer)
  "Update the last active buffer for SESSION-ID to BUFFER."
  (when-let ((session (gethash session-id kimi-code-ide-tools-server--sessions)))
    (plist-put session :last-active-buffer buffer)
    (kimi-code-ide-debug "Updated last active buffer for session %s to %s"
                         session-id (buffer-name buffer))))

(defmacro kimi-code-ide-tools-server-with-session-context (session-id &rest body)
  "Execute BODY with the context of SESSION-ID.
Sets the default-directory to the session's project directory
and makes the session's buffer current if it exists."
  (declare (indent 1))
  `(let* ((context (kimi-code-ide-tools-server-get-session-context ,session-id))
          (project-dir (plist-get context :project-dir))
          (last-active-buffer (plist-get context :last-active-buffer))
          (registered-buffer (plist-get context :buffer))
          (buffer (or (and last-active-buffer
                           (buffer-live-p last-active-buffer)
                           last-active-buffer)
                      (and registered-buffer
                           (buffer-live-p registered-buffer)
                           registered-buffer))))
     (if (not context)
         (error "No session context found for session %s" ,session-id)
       (let ((default-directory (or project-dir default-directory)))
         (if buffer
             (with-current-buffer buffer
               ,@body)
           ,@body)))))

;;; Internal Functions

(defun kimi-code-ide-tools-server--server-alive-p ()
  "Check if the MCP tools server is still alive."
  (when kimi-code-ide-tools-server--server
    (condition-case nil
        (let ((process (ws-process kimi-code-ide-tools-server--server)))
          (and process (process-live-p process)))
      (error nil))))

(defun kimi-code-ide-tools-server--start-server ()
  "Start the MCP HTTP server."
  (condition-case err
      (progn
        (require 'kimi-code-ide-tools-http)
        (unless (featurep 'web-server)
          (error "The web-server package is required for MCP tools support."))
        (let ((result (kimi-code-ide-tools-http-server-start
                       kimi-code-ide-tools-server-port)))
          (setq kimi-code-ide-tools-server--server (car result)
                kimi-code-ide-tools-server--port (cdr result))
          kimi-code-ide-tools-server--port))
    (error
     (kimi-code-ide-debug "Failed to start MCP server: %s"
                          (error-message-string err))
     (message "Warning: Failed to start MCP server: %s"
              (error-message-string err))
     nil)))

(defun kimi-code-ide-tools-server--stop-server ()
  "Stop the MCP HTTP server."
  (when kimi-code-ide-tools-server--server
    (condition-case err
        (progn
          (kimi-code-ide-tools-http-server-stop kimi-code-ide-tools-server--server)
          (setq kimi-code-ide-tools-server--server nil
                kimi-code-ide-tools-server--port nil)
          (clrhash kimi-code-ide-tools-server--sessions)
          (kimi-code-ide-debug "MCP server stopped"))
      (error
       (kimi-code-ide-debug "Error stopping MCP server: %s"
                              (error-message-string err))))))

(provide 'kimi-code-ide-tools-server)

;;; kimi-code-ide-tools-server.el ends here
