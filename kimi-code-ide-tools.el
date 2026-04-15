;;; kimi-code-ide-tools.el --- Emacs tools for Kimi Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, kimi, tools, xref, emacs

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

;; This file provides Emacs-specific tools for Kimi Code IDE.
;; These tools expose Emacs functionality such as xref (cross-references)
;; and project information to Kimi, enabling AI-assisted code navigation
;; and understanding within the correct project context.

;;; Code:

(require 'kimi-code-ide-tools-server)
(require 'xref)
(require 'project)
(require 'cl-lib)
(require 'imenu)

;; Tree-sitter declarations
(declare-function treesit-node-at "treesit" (pos &optional parser-or-lang named))
(declare-function treesit-node-text "treesit" (node &optional no-property))
(declare-function treesit-node-field-name "treesit" (node))

;;; Tool Functions

(defun kimi-code-ide-tools-xref-find-references (identifier file-path)
  "Find references to IDENTIFIER in the current session's project.
FILE-PATH specifies which file's buffer context to use for the search."
  (if (not file-path)
      (error "file_path parameter is required")
    (kimi-code-ide-tools-server-with-session-context nil
      (let ((target-buffer (or (find-buffer-visiting file-path)
                               (find-file-noselect file-path)))
            (identifier-str (format "%s" identifier)))
        (with-current-buffer target-buffer
          (condition-case err
              (let ((backend (xref-find-backend)))
                (if (not backend)
                    (format "No xref backend available for %s" file-path)
                  (let ((xref-items (xref-backend-references backend identifier-str)))
                    (if xref-items
                        (mapcar (lambda (item)
                                  (let* ((location (xref-item-location item))
                                         (file (xref-location-group location))
                                         (marker (xref-location-marker location))
                                         (line (with-current-buffer (marker-buffer marker)
                                                 (save-excursion
                                                   (goto-char marker)
                                                   (line-number-at-pos))))
                                         (summary (xref-item-summary item)))
                                    (format "%s:%d: %s" file line summary)))
                                xref-items)
                      (format "No references found for '%s'" identifier-str)))))
            (error
             (format "Error searching for '%s' in %s: %s"
                     identifier-str file-path (error-message-string err)))))))))

(defun kimi-code-ide-tools-xref-find-apropos (pattern file-path)
  "Find symbols matching PATTERN across the entire project.
FILE-PATH specifies which file's buffer context to use for the search."
  (if (not file-path)
      (error "file_path parameter is required")
    (kimi-code-ide-tools-server-with-session-context nil
      (let ((target-buffer (or (find-buffer-visiting file-path)
                               (find-file-noselect file-path)))
            (pattern-str (format "%s" pattern)))
        (with-current-buffer target-buffer
          (condition-case err
              (let ((backend (xref-find-backend)))
                (cond
                 ((not backend)
                  (format "No xref backend available for %s" file-path))
                 ((and (eq backend 'etags)
                       (not (or (and (boundp 'tags-file-name) tags-file-name
                                     (file-exists-p tags-file-name))
                                (and (boundp 'tags-table-list) tags-table-list
                                     (cl-some #'file-exists-p tags-table-list)))))
                  (format "No tags table available for %s" file-path))
                 (t
                  (let ((xref-items (xref-backend-apropos backend pattern-str)))
                    (if xref-items
                        (mapcar (lambda (item)
                                  (let* ((location (xref-item-location item))
                                         (file (xref-location-group location))
                                         (marker (xref-location-marker location))
                                         (line (with-current-buffer (marker-buffer marker)
                                                 (save-excursion
                                                   (goto-char marker)
                                                   (line-number-at-pos))))
                                         (summary (xref-item-summary item)))
                                    (format "%s:%d: %s" file line summary)))
                                xref-items)
                      (format "No symbols found matching pattern '%s'" pattern-str))))))
            (error
             (format "Error searching for pattern '%s' in %s: %s"
                     pattern-str file-path (error-message-string err)))))))))

(defun kimi-code-ide-tools-project-info ()
  "Get information about the current session's project.
Returns project directory, active buffer, and file count."
  (let ((context (kimi-code-ide-tools-server-get-session-context)))
    (if context
        (let ((project-dir (plist-get context :project-dir))
              (buffer (plist-get context :buffer)))
          (format "Project: %s\nBuffer: %s\nFiles: %d"
                  project-dir
                  (if (and buffer (buffer-live-p buffer))
                      (buffer-name buffer)
                    "No active buffer")
                  (length (project-files (project-current nil project-dir)))))
      "No session context available")))

(defun kimi-code-ide-tools-imenu-list-symbols (file-path)
  "List all symbols in FILE-PATH using imenu.
Returns a list of symbols with their types and positions."
  (if (not file-path)
      (error "file_path parameter is required")
    (kimi-code-ide-tools-server-with-session-context nil
      (condition-case err
          (let ((target-buffer (or (find-buffer-visiting file-path)
                                   (find-file-noselect file-path))))
            (with-current-buffer target-buffer
              (imenu--make-index-alist)
              (if imenu--index-alist
                  (let ((results '()))
                    (dolist (item imenu--index-alist)
                      (cond
                       ((string-match-p "^\\*" (car item)) nil)
                       ((markerp (cdr item))
                        (let ((line (line-number-at-pos (marker-position (cdr item)))))
                          (push (format "%s:%d: %s"
                                        file-path
                                        line
                                        (car item))
                                results)))
                       ((numberp (cdr item))
                        (let ((line (line-number-at-pos (cdr item))))
                          (push (format "%s:%d: %s"
                                        file-path
                                        line
                                        (car item))
                                results)))
                       ((listp (cdr item))
                        (let ((category (car item)))
                          (dolist (subitem (cdr item))
                            (when (and (consp subitem)
                                       (or (markerp (cdr subitem))
                                           (numberp (cdr subitem))))
                              (let ((line (line-number-at-pos
                                           (if (markerp (cdr subitem))
                                               (marker-position (cdr subitem))
                                             (cdr subitem)))))
                                (push (format "%s:%d: [%s] %s"
                                              file-path
                                              line
                                              category
                                              (car subitem))
                                      results))))))))
                    (if results
                        (nreverse results)
                      (format "No symbols found in %s" file-path)))
                (format "No imenu support or no symbols found in %s" file-path))))
        (error
         (format "Error listing symbols in %s: %s"
                 file-path (error-message-string err)))))))

(defun kimi-code-ide-tools-treesit--format-tree (node level max-depth)
  "Format NODE and its children as a tree string.
LEVEL is the current indentation level.
MAX-DEPTH is the maximum depth to traverse."
  (if (or (not node) (>= level max-depth))
      ""
    (let* ((indent (make-string (* level 2) ?\s))
           (type (treesit-node-type node))
           (named (if (treesit-node-check node 'named) " (named)" ""))
           (start (treesit-node-start node))
           (end (treesit-node-end node))
           (field-name (treesit-node-field-name node))
           (field-str (if field-name (format " [%s]" field-name) ""))
           (text (treesit-node-text node t))
           (text-preview (if (and (< (length text) 40)
                                  (not (string-match-p "\n" text)))
                             (format " \"%s\"" text)
                           ""))
           (result (format "%s%s%s%s (%d-%d)%s\n"
                           indent type named field-str
                           start end text-preview))
           (child-count (treesit-node-child-count node)))
      (dotimes (i child-count)
        (when-let ((child (treesit-node-child node i)))
          (setq result (concat result
                               (kimi-code-ide-tools-treesit--format-tree
                                child (1+ level) max-depth)))))
      result)))

(defun kimi-code-ide-tools--line-column-to-point (line column)
  "Convert LINE and COLUMN to point position in current buffer.
LINE is 1-based, COLUMN is 0-based (Emacs convention)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)
    (point)))

(defun kimi-code-ide-tools-treesit-info (file-path &optional line column whole_file include_ancestors include_children)
  "Get tree-sitter parse tree information for FILE-PATH.
Optional LINE and COLUMN specify the position (1-based line, 0-based column).
If WHOLE_FILE is non-nil, show the entire file's syntax tree.
If neither position is specified, defaults to current cursor position (point).
If INCLUDE_ANCESTORS is non-nil, include parent node hierarchy.
If INCLUDE_CHILDREN is non-nil, include child nodes."
  (if (not file-path)
      (error "file_path parameter is required")
    (kimi-code-ide-tools-server-with-session-context nil
      (condition-case err
          (if (not (treesit-available-p))
              "Tree-sitter is not available in this Emacs build"
            (let ((target-buffer (or (find-buffer-visiting file-path)
                                     (find-file-noselect file-path))))
              (with-current-buffer target-buffer
                (let* ((parsers (treesit-parser-list))
                       (parser (car parsers)))
                  (if (not parser)
                      (format "No tree-sitter parser available for %s" file-path)
                    (let* ((root-node (treesit-parser-root-node parser))
                           (pos (cond (whole_file nil)
                                      (line (kimi-code-ide-tools--line-column-to-point
                                             line (or column 0)))
                                      (t (point))))
                           (node (if whole_file
                                     root-node
                                   (treesit-node-at pos parser)))
                           (results '()))
                      (if (not node)
                          "No tree-sitter node found"
                        (if whole_file
                            (kimi-code-ide-tools-treesit--format-tree root-node 0 20)
                          (push (format "Node Type: %s" (treesit-node-type node)) results)
                          (push (format "Range: %d-%d"
                                        (treesit-node-start node)
                                        (treesit-node-end node)) results)
                          (push (format "Text: %s"
                                        (truncate-string-to-width
                                         (treesit-node-text node t)
                                         80 nil nil "...")) results)
                          (when (treesit-node-check node 'named)
                            (push "Named: yes" results))
                          (let ((field-name (treesit-node-field-name node)))
                            (when field-name
                              (push (format "Field: %s" field-name) results)))
                          (when include_ancestors
                            (push "\nAncestors:" results)
                            (let ((parent (treesit-node-parent node))
                                  (level 1))
                              (while (and parent (< level 10))
                                (push (format "  %s[%d] %s (%d-%d)"
                                              (make-string level ?-)
                                              level
                                              (treesit-node-type parent)
                                              (treesit-node-start parent)
                                              (treesit-node-end parent))
                                      results)
                                (setq parent (treesit-node-parent parent))
                                (cl-incf level))))
                          (when include_children
                            (push "\nChildren:" results)
                            (let ((child-count (treesit-node-child-count node))
                                  (i 0))
                              (if (= child-count 0)
                                  (push "  (no children)" results)
                                (while (< i (min child-count 20))
                                  (let ((child (treesit-node-child node i)))
                                    (when child
                                      (push (format "  [%d] %s%s (%d-%d)"
                                                    i
                                                    (treesit-node-type child)
                                                    (if (treesit-node-check child 'named)
                                                        " (named)" "")
                                                    (treesit-node-start child)
                                                    (treesit-node-end child))
                                            results)))
                                  (cl-incf i))
                                (when (> child-count 20)
                                  (push (format "  ... and %d more children"
                                                (- child-count 20))
                                        results)))))
                          (string-join (nreverse results) "\n")))))))))
        (error
         (format "Error getting tree-sitter info for %s: %s"
                 file-path (error-message-string err)))))))

;;; Setup Function

;;;###autoload
(defun kimi-code-ide-tools-setup ()
  "Set up Emacs tools for Kimi Code IDE."
  (interactive)
  (setq kimi-code-ide-enable-tools-server t)

  (kimi-code-ide-tools-server-make-tool
   :function #'kimi-code-ide-tools-xref-find-references
   :name "xref-find-references"
   :description "Find where a function, variable, or class is used throughout your codebase."
   :args '((:name "identifier"
                  :type string
                  :description "The identifier to find references for")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (kimi-code-ide-tools-server-make-tool
   :function #'kimi-code-ide-tools-xref-find-apropos
   :name "xref-find-apropos"
   :description "Search for functions, variables, or classes by name pattern across your project."
   :args '((:name "pattern"
                  :type string
                  :description "The pattern to search for symbols")
           (:name "file_path"
                  :type string
                  :description "File path to use as context for the search")))

  (kimi-code-ide-tools-server-make-tool
   :function #'kimi-code-ide-tools-project-info
   :name "project-info"
   :description "Get quick overview of your current project context."
   :args nil)

  (kimi-code-ide-tools-server-make-tool
   :function #'kimi-code-ide-tools-imenu-list-symbols
   :name "imenu-list-symbols"
   :description "Navigate and explore a file's structure by listing all its functions, classes, and variables."
   :args '((:name "file_path"
                  :type string
                  :description "Path to the file to analyze for symbols")))

  (kimi-code-ide-tools-server-make-tool
   :function #'kimi-code-ide-tools-treesit-info
   :name "treesit-info"
   :description "Get tree-sitter syntax tree information for a file."
   :args '((:name "file_path"
                  :type string
                  :description "Path to the file to analyze")
           (:name "line"
                  :type number
                  :description "Line number (1-based)"
                  :optional t)
           (:name "column"
                  :type number
                  :description "Column number (0-based)"
                  :optional t)
           (:name "whole_file"
                  :type boolean
                  :description "Show the entire file's syntax tree"
                  :optional t)
           (:name "include_ancestors"
                  :type boolean
                  :description "Include parent node hierarchy"
                  :optional t)
           (:name "include_children"
                  :type boolean
                  :description "Include child nodes"
                  :optional t))))

(provide 'kimi-code-ide-tools)

;;; kimi-code-ide-tools.el ends here
