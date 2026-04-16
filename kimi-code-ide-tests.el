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

;; Stub acp package for batch testing when the real dependency is unavailable
(eval-and-compile
  (unless (locate-library "acp")
    (provide 'acp)
    (defun acp-make-client (&rest _))
    (defun acp--client-started-p (&rest _) nil)
    (defun acp--start-client (&rest _))
    (defun acp-subscribe-to-notifications (&rest _))
    (defun acp-subscribe-to-requests (&rest _))
    (defun acp-subscribe-to-errors (&rest _))
    (defun acp-make-initialize-request (&rest _) nil)
    (defun acp-make-session-new-request (&rest _) nil)
    (defun acp-send-request (&rest _) nil)
    (defun acp-send-notification (&rest _) nil)
    (defun acp-send-response (&rest _) nil)
    (defun acp-make-session-prompt-request (&rest _) nil)
    (defun acp-make-session-cancel-notification (&rest _) nil)
    (defun acp-make-error (&rest _) nil)
    (defun acp-make-fs-read-text-file-response (&rest _) nil)
    (defun acp-make-fs-write-text-file-response (&rest _) nil)
    (defun acp-make-session-request-permission-response (&rest _) nil)
    (defun acp-shutdown (&rest _) nil)))

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
    (should (string= (kimi-code-ide--get-working-directory) "/tmp"))))

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

;;; Resume Tests

(ert-deftest kimi-code-ide-test-buffer-has-history-p ()
  "Test detection of existing conversation history in buffer."
  (with-temp-buffer
    (rename-buffer "*kimi-test-history*" t)
    (kimi-code-ide-mode)
    (should (not (kimi-code-ide--buffer-has-history-p)))
    (insert "* Kimi Code IDE — test\n\n")
    (should (not (kimi-code-ide--buffer-has-history-p)))
    (insert "* You\nHello\n")
    (should (kimi-code-ide--buffer-has-history-p))))

(ert-deftest kimi-code-ide-test-pending-resume-history-project-scoped ()
  "Test that pending resume history is scoped per project."
  (puthash "/tmp/project-a" "history A" kimi-code-ide--pending-resume-history)
  (puthash "/tmp/project-b" "history B" kimi-code-ide--pending-resume-history)
  (should (string= (gethash "/tmp/project-a" kimi-code-ide--pending-resume-history) "history A"))
  (should (string= (gethash "/tmp/project-b" kimi-code-ide--pending-resume-history) "history B"))
  (remhash "/tmp/project-a" kimi-code-ide--pending-resume-history)
  (remhash "/tmp/project-b" kimi-code-ide--pending-resume-history))

(ert-deftest kimi-code-ide-test-parse-context-jsonl-multiline ()
  "Test parsing of multi-line JSONL context files."
  (let ((file (make-temp-file "kimi-context-" nil ".jsonl")))
    (with-temp-file file
      (insert "{\"role\":\"user\",\"content\":\"hello\"}\n")
      (insert "{\n  \"role\": \"assistant\",\n  \"content\": \"world\"\n}\n")
      (insert "{\"role\":\"user\",\"content\":\"foo\"}\n")
      (insert "{\"role\":\"assistant\",\"content\":\"bar\"}\n"))
    (let ((turns (kimi-code-ide--parse-context-jsonl file)))
      (should (= (length turns) 2))
      (should (string= (caar turns) "hello"))
      (should (string= (cdar turns) "world"))
      (should (string= (caadr turns) "foo"))
      (should (string= (cdadr turns) "bar")))
    (delete-file file)))

(ert-deftest kimi-code-ide-test-parse-context-jsonl-tool-string ()
  "Test that plain string tool results are included in parsed turns."
  (let ((file (make-temp-file "kimi-context-" nil ".jsonl")))
    (with-temp-file file
      (insert "{\"role\":\"user\",\"content\":\"search\"}\n")
      (insert "{\"role\":\"assistant\",\"content\":\"Let me search.\"}\n")
      (insert "{\"role\":\"tool\",\"content\":\"Search result: Emacs\"}\n")
      (insert "{\"role\":\"assistant\",\"content\":\"Here is the result.\"}\n"))
    (let ((turns (kimi-code-ide--parse-context-jsonl file)))
      (should (= (length turns) 1))
      (should (string= (caar turns) "search"))
      (should (string-match-p "Search result: Emacs" (cdar turns)))
      (should (string-match-p "Here is the result." (cdar turns))))
    (delete-file file)))

;;; Slash Command Tests

(ert-deftest kimi-code-ide-test-slash-command-registry ()
  "Test that slash command registry contains expected commands."
  (should (assoc "\\init" kimi-code-ide-slash-commands))
  (should (assoc "\\stop" kimi-code-ide-slash-commands))
  (should (assoc "\\resume" kimi-code-ide-slash-commands))
  (should (assoc "\\clear" kimi-code-ide-slash-commands))
  (should (assoc "\\cancel" kimi-code-ide-slash-commands))
  (should (assoc "\\import" kimi-code-ide-slash-commands))
  (should (assoc "\\help" kimi-code-ide-slash-commands)))

(ert-deftest kimi-code-ide-test-slash-completion-at-point ()
  "Test slash completion returns candidates in input buffer."
  (with-temp-buffer
    (kimi-code-ide-input-mode)
    (insert "\\ini")
    (let ((result (kimi-code-ide--slash-completion-at-point)))
      (should result)
      (let ((candidates (nth 2 result)))
        (should (member "init" candidates))))))

(ert-deftest kimi-code-ide-test-slash-completion-no-trigger ()
  "Test slash completion does not trigger without leading backslash."
  (with-temp-buffer
    (kimi-code-ide-input-mode)
    (insert "init")
    (should (not (kimi-code-ide--slash-completion-at-point)))))

(ert-deftest kimi-code-ide-test-slash-completion-not-at-bol ()
  "Test slash completion does not trigger mid-line."
  (with-temp-buffer
    (kimi-code-ide-input-mode)
    (insert "hello \\init")
    (should (not (kimi-code-ide--slash-completion-at-point)))))

;;; Test Runner

(defun kimi-code-ide-run-tests ()
  "Run all Kimi Code IDE tests."
  (interactive)
  (ert-run-tests-batch-and-exit "^kimi-code-ide-test-"))

(provide 'kimi-code-ide-tests)

;;; kimi-code-ide-tests.el ends here
