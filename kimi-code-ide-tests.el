;;; kimi-code-ide-tests.el --- Tests for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, test

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

;; ERT tests for Kimi Code IDE.

;;; Code:

(require 'ert)
(require 'kimi-code-ide)
(require 'kimi-code-ide-acp)
(require 'kimi-code-ide-debug)
(require 'kimi-code-ide-diagnostics)
(require 'kimi-code-ide-tools-server)
(require 'kimi-code-ide-tools-http)

(declare-function kimi-code-ide-tools-http-server--required-args "kimi-code-ide-tools-http" (args))

;;; Buffer Name Tests

(ert-deftest kimi-code-ide-test-buffer-name ()
  "Test default buffer name generation."
  (let ((name (kimi-code-ide--default-buffer-name "/home/user/my-project/")))
    (should (string= name "*kimi-code[my-project]*"))))

(ert-deftest kimi-code-ide-test-buffer-name-no-trailing-slash ()
  "Test buffer name generation without trailing slash."
  (let ((name (kimi-code-ide--default-buffer-name "/home/user/my-project")))
    (should (string= name "*kimi-code[my-project]*"))))

;;; Working Directory Tests

(ert-deftest kimi-code-ide-test-working-directory ()
  "Test working directory detection."
  (let ((default-directory "/tmp/"))
    (should (string= (kimi-code-ide--get-working-directory) "/tmp/"))))

;;; ACP Client Tests

(ert-deftest kimi-code-ide-test-acp-session-struct ()
  "Test ACP session structure creation."
  (let ((session (make-kimi-code-ide-acp-session
                  :client 'test-client
                  :project-dir "/tmp/test"
                  :buffer (get-buffer-create "*test*"))))
    (should (eq (kimi-code-ide-acp-session-client session) 'test-client))
    (should (string= (kimi-code-ide-acp-session-project-dir session) "/tmp/test"))
    (should (buffer-live-p (kimi-code-ide-acp-session-buffer session)))))

(ert-deftest kimi-code-ide-test-acp-render-function ()
  "Test render function registration."
  (let ((fn (lambda (_type _data) 'called)))
    (kimi-code-ide-acp--set-render-function "/tmp/test" fn)
    (should (eq (funcall (gethash "/tmp/test" kimi-code-ide-acp--render-functions) 'test nil)
                'called))
    (remhash "/tmp/test" kimi-code-ide-acp--render-functions)))

;;; Debug Tests

(ert-deftest kimi-code-ide-test-debug-buffer ()
  "Test debug buffer creation."
  (let ((buffer (kimi-code-ide--debug-buffer)))
    (should (buffer-live-p buffer))
    (should (string= (buffer-name buffer) kimi-code-ide-debug-buffer))))

;;; Diagnostics Tests

(ert-deftest kimi-code-ide-test-uri-to-file-path ()
  "Test URI to file path conversion."
  (should (string= (kimi-code-ide-uri-to-file-path "file:///home/user/test.el")
                   "/home/user/test.el"))
  (should (string= (kimi-code-ide-uri-to-file-path "/home/user/test.el")
                   "/home/user/test.el")))

(ert-deftest kimi-code-ide-test-file-path-to-uri ()
  "Test file path to URI conversion."
  (should (string= (kimi-code-ide-file-path-to-uri "/home/user/test.el")
                   "file:///home/user/test.el")))

(ert-deftest kimi-code-ide-test-diagnostics-severity ()
  "Test diagnostic severity conversion."
  (should (string= (kimi-code-ide-diagnostics--severity-to-string 'error) "Error"))
  (should (string= (kimi-code-ide-diagnostics--severity-to-string 'warning) "Warning"))
  (should (string= (kimi-code-ide-diagnostics--severity-to-string 'flymake-note) "Information")))

;;; Tools Server Tests

(ert-deftest kimi-code-ide-test-tool-format-detection ()
  "Test tool format detection."
  (should (eq (kimi-code-ide-tools-server--tool-format-p
               '(:function #'test :name "test" :description "test"))
              'new))
  (should (eq (kimi-code-ide-tools-server--tool-format-p
               '(test :description "test" :parameters nil))
              'old)))

(ert-deftest kimi-code-ide-test-normalize-tool-spec ()
  "Test tool spec normalization."
  (let ((normalized (kimi-code-ide-tools-server--normalize-tool-spec
                     '(:function identity :name "test" :description "A test tool"))))
    (should (eq (plist-get normalized :function) 'identity))
    (should (string= (plist-get normalized :name) "test"))
    (should (string= (plist-get normalized :description) "A test tool"))))

(ert-deftest kimi-code-ide-test-required-args ()
  "Test required args extraction."
  (should (equal (kimi-code-ide-tools-http-server--required-args
                  '((:name "foo" :type string)
                    (:name "bar" :type string :optional t)
                    (:name "baz" :type number)))
                 ["foo" "baz"])))

;;; Integration Tests

(ert-deftest kimi-code-ide-test-session-cleanup ()
  "Test session cleanup."
  (let ((test-dir "/tmp/kimi-test-project")
        (_buffer-name "*kimi-code[kimi-test-project]*"))
    (puthash test-dir "session-123" kimi-code-ide--session-ids)
    (remhash test-dir kimi-code-ide--session-ids)
    (should (not (gethash test-dir kimi-code-ide--session-ids)))))

;;; Test Runner

(defun kimi-code-ide-run-tests ()
  "Run all Kimi Code IDE tests."
  (interactive)
  (ert-run-tests-batch-and-exit "^kimi-code-ide-test-"))

(provide 'kimi-code-ide-tests)

;;; kimi-code-ide-tests.el ends here
