;;; kimi-code-ide-tools-http.el --- HTTP server for MCP tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, mcp, http

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

;; This module implements the HTTP server for the MCP tools server.
;; It uses the web-server package to handle HTTP requests and implements
;; the MCP Streamable HTTP transport protocol.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'url-parse)
(require 'kimi-code-ide-debug)
(require 'kimi-code-ide-tools-server)

(defvar kimi-code-ide-tools-server--current-session-id)

;; Require web-server at runtime to avoid batch mode issues
(unless (featurep 'web-server)
  (condition-case err
      (require 'web-server)
    (error
     (kimi-code-ide-debug "Failed to load web-server package: %s" (error-message-string err)))))

;; Web-server declarations
(declare-function ws-process "web-server" (server))
(declare-function ws-start "web-server" (handlers port &optional log-buffer &rest network-args))
(declare-function ws-stop "web-server" (server))
(declare-function ws-send-404 "web-server" (proc &optional info))
(declare-function ws-headers "web-server" (request))
(declare-function ws-body "web-server" (request))
(declare-function ws-send "web-server" (proc msg))
(declare-function ws-response-header "web-server" (proc code &rest headers))

;;; Server State

(defvar kimi-code-ide-tools-http-server--server nil
  "The web-server instance.")

;;; Helper Functions

(defun kimi-code-ide-tools-http-server--extract-session-id-from-path (headers)
  "Extract session ID from URL path in HEADERS."
  (let* ((url (or (cdr (assoc :POST headers))
                  (cdr (assoc :GET headers)))))
    (when (and url (string-match "^/mcp/\\([^/?]+\\)" url))
      (match-string 1 url))))

;;; Public Functions

(defun kimi-code-ide-tools-http-server-start (&optional port)
  "Start the MCP HTTP server on PORT.
Returns a cons cell of (server . port)."
  (unless (featurep 'web-server)
    (error "web-server package is not available"))
  (kimi-code-ide-debug "Attempting to start MCP server on port %s" (or port "auto"))
  (condition-case err
      (let* ((selected-port (or port 0))
             (server (ws-start
                      `(((:GET . "^/mcp\\(/.*\\)?$") . ,#'kimi-code-ide-tools-http-server--handle-get)
                        ((:POST . "^/mcp\\(/.*\\)?$") . ,#'kimi-code-ide-tools-http-server--handle-post))
                      selected-port
                      nil
                      :host "127.0.0.1")))
        (setq kimi-code-ide-tools-http-server--server server)
        (let* ((process (ws-process server))
               (actual-port (process-contact process :service)))
          (kimi-code-ide-debug "MCP server started on port %d" actual-port)
          (set-process-sentinel process
                                (lambda (_proc event)
                                  (kimi-code-ide-debug "MCP server process event: %s" event)))
          (cons server actual-port)))
    (error
     (kimi-code-ide-debug "Failed to start web server: %s" (error-message-string err))
     (signal 'error (list (format "Failed to start web server: %s" (error-message-string err)))))))

(defun kimi-code-ide-tools-http-server-stop (server)
  "Stop the MCP HTTP server SERVER."
  (when server
    (ws-stop server)
    (setq kimi-code-ide-tools-http-server--server nil)))

;;; Request Handlers

(defun kimi-code-ide-tools-http-server--handle-get (request)
  "Handle GET request to /mcp endpoint."
  (ws-send-404 (ws-process request)))

(defun kimi-code-ide-tools-http-server--handle-post (request)
  "Handle POST request to /mcp/* endpoints."
  (kimi-code-ide-debug "MCP server received POST request")
  (condition-case err
      (let* ((headers (ws-headers request))
             (body (ws-body request))
             (url-session-id (kimi-code-ide-tools-http-server--extract-session-id-from-path headers))
             (json-object (json-parse-string body :object-type 'alist))
             (method (alist-get 'method json-object))
             (params (alist-get 'params json-object))
             (id (alist-get 'id json-object)))
        (kimi-code-ide-debug "MCP request - method: %s, id: %s, session-id: %s"
                             method id url-session-id)
        (if (null id)
            (progn
              (kimi-code-ide-debug "Received notification: %s" method)
              (kimi-code-ide-tools-http-server--send-empty-response request))
          (let* ((kimi-code-ide-tools-server--current-session-id url-session-id)
                 (result (kimi-code-ide-tools-http-server--dispatch method params)))
            (kimi-code-ide-debug "MCP response result computed")
            (kimi-code-ide-tools-http-server--send-json-response
             request 200
             `((jsonrpc . "2.0")
               (id . ,id)
               (result . ,result)))
            (kimi-code-ide-debug "MCP response sent"))))
    (json-parse-error
     (kimi-code-ide-tools-http-server--send-json-error
      request nil -32700 "Parse error"))
    (quit
     (kimi-code-ide-debug "Request cancelled by user")
     (kimi-code-ide-tools-http-server--send-json-error
      request nil -32001 "Operation cancelled by user"))
    (error
     (kimi-code-ide-debug "Error handling request: %s" (error-message-string err))
     (kimi-code-ide-tools-http-server--send-json-error
      request nil -32603 (format "Internal error: %s" (error-message-string err))))))

;;; MCP Protocol Implementation

(defun kimi-code-ide-tools-http-server--dispatch (method params)
  "Dispatch MCP method calls."
  (pcase method
    ("initialize"
     (kimi-code-ide-tools-http-server--handle-initialize params))
    ("tools/list"
     (kimi-code-ide-tools-http-server--handle-tools-list params))
    ("tools/call"
     (kimi-code-ide-tools-http-server--handle-tools-call params))
    (_
     (signal 'json-rpc-error (list -32601 "Method not found")))))

(defun kimi-code-ide-tools-http-server--handle-initialize (_params)
  "Handle the initialize method."
  `((protocolVersion . "2024-11-05")
    (capabilities . ((tools . ((listChanged . :json-false)))
                     (logging . ,(make-hash-table :test 'equal))))
    (serverInfo . ((name . "kimi-code-ide-tools")
                   (version . "0.1.0")))))

(defun kimi-code-ide-tools-http-server--handle-tools-list (_params)
  "Handle the tools/list method."
  (let ((tools (mapcar (lambda (spec)
                         (kimi-code-ide-tools-http-server--tool-to-mcp
                          (kimi-code-ide-tools-server--normalize-tool-spec spec)))
                       kimi-code-ide-tools-server-tools)))
    (kimi-code-ide-debug "MCP server returning %d tools" (length tools))
    `((tools . ,tools))))

(defun kimi-code-ide-tools-http-server--handle-tools-call (params)
  "Handle the tools/call method with PARAMS."
  (let* ((tool-name (alist-get 'name params))
         (tool-args (alist-get 'arguments params))
         (tool-spec (cl-find-if
                     (lambda (spec)
                       (let ((normalized (kimi-code-ide-tools-server--normalize-tool-spec spec)))
                         (string= (or (plist-get normalized :name)
                                      (symbol-name (plist-get normalized :function)))
                                  tool-name)))
                     kimi-code-ide-tools-server-tools)))
    (unless tool-spec
      (signal 'json-rpc-error (list -32602 (format "Unknown tool: %s" tool-name))))
    (let* ((normalized (kimi-code-ide-tools-server--normalize-tool-spec tool-spec))
           (tool-function (plist-get normalized :function))
           (arg-specs (plist-get normalized :args))
           (args (kimi-code-ide-tools-http-server--validate-args tool-args arg-specs)))
      (condition-case err
          (let ((result (apply tool-function args)))
            `((content . (((type . "text")
                           (text . ,(kimi-code-ide-tools-http-server--format-result result)))))))
        (quit
         `((content . (((type . "text")
                        (text . "Operation cancelled by user"))))))
        (error
         `((content . (((type . "text")
                        (text . ,(format "Error: %s" (error-message-string err))))))))))))

;;; Helper Functions

(defun kimi-code-ide-tools-http-server--tool-to-mcp (tool-spec)
  "Convert TOOL-SPEC to MCP tool format."
  (let* ((name (or (plist-get tool-spec :name)
                   (symbol-name (plist-get tool-spec :function))))
         (description (plist-get tool-spec :description))
         (args (plist-get tool-spec :args)))
    `((name . ,name)
      (description . ,description)
      (inputSchema . ((type . "object")
                      (properties . ,(kimi-code-ide-tools-http-server--args-to-schema args))
                      (required . ,(kimi-code-ide-tools-http-server--required-args args)))))))

(defun kimi-code-ide-tools-http-server--args-to-schema (args)
  "Convert ARGS list to JSON Schema properties."
  (if args
      (let ((schema '()))
        (dolist (arg args (nreverse schema))
          (let* ((name (plist-get arg :name))
                 (type (plist-get arg :type))
                 (desc (plist-get arg :description))
                 (prop-schema `((type . ,(if (symbolp type)
                                             (symbol-name type)
                                           type)))))
            (when desc
              (setq prop-schema (append prop-schema `((description . ,desc)))))
            (push (cons (intern name) prop-schema) schema))))
    (make-hash-table :test 'equal)))

(defun kimi-code-ide-tools-http-server--required-args (args)
  "Extract required argument names from ARGS."
  (let ((required '()))
    (dolist (arg args)
      (unless (plist-get arg :optional)
        (push (plist-get arg :name) required)))
    (vconcat (nreverse required))))

(defun kimi-code-ide-tools-http-server--validate-args (args arg-specs)
  "Validate and extract ARGS according to ARG-SPECS."
  (let ((result '()))
    (dolist (spec arg-specs (nreverse result))
      (let* ((name (plist-get spec :name))
             (optional (plist-get spec :optional))
             (value (alist-get (intern name) args)))
        (when (and (not optional) (not value))
          (signal 'json-rpc-error
                  (list -32602 (format "Missing required argument: %s" name))))
        (push value result)))))

(defun kimi-code-ide-tools-http-server--format-result (result)
  "Format RESULT for display."
  (cond
   ((stringp result) result)
   ((listp result)
    (mapconcat (lambda (item)
                 (format "%s" item))
               result "\n"))
   (t (format "%s" result))))

(defun kimi-code-ide-tools-http-server--send-json-response (request status body)
  "Send JSON response to REQUEST with STATUS and BODY."
  (let ((process (ws-process request))
        (headers (list (cons "Content-Type" "application/json")
                       (cons "Access-Control-Allow-Origin" "*"))))
    (apply #'ws-response-header process status headers)
    (ws-send process (json-encode body))
    (throw 'close-connection nil)))

(defun kimi-code-ide-tools-http-server--send-empty-response (request)
  "Send an empty HTTP 200 response for notifications."
  (let ((process (ws-process request)))
    (ws-response-header process 200
                        (cons "Content-Type" "text/plain")
                        (cons "Content-Length" "0"))
    (throw 'close-connection nil)))

(defun kimi-code-ide-tools-http-server--send-json-error (request id code message)
  "Send JSON-RPC error response."
  (kimi-code-ide-tools-http-server--send-json-response
   request 200
   `((jsonrpc . "2.0")
     (id . ,id)
     (error . ((code . ,code)
               (message . ,message))))))

(provide 'kimi-code-ide-tools-http)

;;; kimi-code-ide-tools-http.el ends here
