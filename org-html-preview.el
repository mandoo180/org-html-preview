;;; org-html-preview.el --- Live preview org files as HTML in browser -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Kyeongsoo Choi <mandoo180@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (simple-httpd "1.5.1") (websocket "1.14"))
;; Keywords: org, html, preview, live-reload
;; URL: https://github.com/mandoo180/org-html-preview

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-html-preview provides a minor mode for live previewing org-mode files
;; as HTML in your browser.  When the minor mode is activated, saving the
;; org buffer automatically exports it to HTML and refreshes the browser
;; via WebSocket connection.
;;
;; Features:
;; - Automatic HTML export on save
;; - WebSocket-based instant browser refresh
;; - GitHub-flavored markdown styling
;; - Multiple buffer support
;; - Modeline indicator showing server status
;;
;; Usage:
;;   M-x org-html-preview-mode    ; Toggle preview mode
;;   M-x org-html-preview-open    ; Open preview in browser
;;   M-x org-html-preview-stop    ; Stop the preview server

;;; Code:

(require 'org)
(require 'ox-html)
(require 'simple-httpd)
(require 'websocket)
(require 'json)

;;; Customization

(defgroup org-html-preview nil
  "Live preview org files as HTML in browser."
  :group 'org
  :prefix "org-html-preview-")

(defcustom org-html-preview-port-range '(9876 9900)
  "Port range for the HTTP server.
The server will try ports in this range until it finds an available one."
  :type '(list integer integer)
  :group 'org-html-preview)

(defcustom org-html-preview-websocket-port-range '(9901 9925)
  "Port range for the WebSocket server.
The server will try ports in this range until it finds an available one."
  :type '(list integer integer)
  :group 'org-html-preview)

(defcustom org-html-preview-auto-open-browser t
  "Whether to automatically open the browser when preview mode is activated."
  :type 'boolean
  :group 'org-html-preview)

(defcustom org-html-preview-browser-function #'browse-url
  "Function used to open the preview in browser."
  :type 'function
  :group 'org-html-preview)

(defcustom org-html-preview-temp-dir nil
  "Directory for temporary HTML files.
If nil, uses a subdirectory in `temporary-file-directory'."
  :type '(choice (const :tag "Default temp directory" nil)
                 (directory :tag "Custom directory"))
  :group 'org-html-preview)

;;; Internal Variables

(defvar org-html-preview--server-running nil
  "Non-nil if the HTTP server is running.")

(defvar org-html-preview--http-port nil
  "Current HTTP server port.")

(defvar org-html-preview--ws-port nil
  "Current WebSocket server port.")

(defvar org-html-preview--ws-server nil
  "The WebSocket server instance.")

(defvar org-html-preview--ws-clients '()
  "List of connected WebSocket clients.")

(defvar org-html-preview--tracked-buffers '()
  "List of buffers with org-html-preview-mode active.")

(defvar org-html-preview--temp-directory nil
  "The temporary directory for HTML files.")

(defvar org-html-preview--file-mapping (make-hash-table :test 'equal)
  "Hash table mapping org file paths to their HTML output paths.")

;;; HTML Template

(defconst org-html-preview--html-template
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>%s</title>
    <link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/github-markdown-css/5.5.1/github-markdown.min.css\">
    <link rel=\"stylesheet\" href=\"style.css\">
    <!-- MathJax for LaTeX rendering -->
    <script>
    MathJax = {
        tex: {
            inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
            displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
            processEscapes: true
        },
        options: {
            skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
        }
    };
    </script>
    <script src=\"https://cdnjs.cloudflare.com/ajax/libs/mathjax/3.2.2/es5/tex-mml-chtml.min.js\"></script>
</head>
<body>
    <div id=\"ws-status\" class=\"disconnected\">Disconnected</div>
    <article class=\"markdown-body\">
%s
    </article>
    <script>window.ORG_PREVIEW_WS_PORT = %d;</script>
    <script src=\"live-reload.js\"></script>
</body>
</html>"
  "HTML template for preview pages.
Contains placeholders for: title, content, websocket port.
References external style.css and live-reload.js files.
Includes MathJax for LaTeX math rendering.")

;;; Utility Functions

(defun org-html-preview--package-directory ()
  "Return the directory where org-html-preview is installed."
  (file-name-directory (or load-file-name buffer-file-name)))

(defun org-html-preview--get-temp-directory ()
  "Get or create the temporary directory for HTML files."
  (unless org-html-preview--temp-directory
    (setq org-html-preview--temp-directory
          (or org-html-preview-temp-dir
              (expand-file-name "org-html-preview"
                                temporary-file-directory))))
  (unless (file-exists-p org-html-preview--temp-directory)
    (make-directory org-html-preview--temp-directory t))
  org-html-preview--temp-directory)

(defun org-html-preview--copy-static-assets ()
  "Copy static assets (CSS, JS) to the temp directory."
  (let* ((pkg-dir (org-html-preview--package-directory))
         (public-dir (expand-file-name "public" pkg-dir))
         (temp-dir (org-html-preview--get-temp-directory)))
    (dolist (file '("style.css" "live-reload.js"))
      (let ((src (expand-file-name file public-dir))
            (dst (expand-file-name file temp-dir)))
        (when (file-exists-p src)
          (copy-file src dst t))))))

(defun org-html-preview--find-available-port (min-port max-port)
  "Find an available port between MIN-PORT and MAX-PORT."
  (let ((port min-port)
        (found nil))
    (while (and (not found) (<= port max-port))
      (condition-case nil
          (let ((server (make-network-process
                         :name "port-test"
                         :host 'local
                         :service port
                         :server t
                         :noquery t)))
            (delete-process server)
            (setq found port))
        (error (setq port (1+ port)))))
    found))

(defun org-html-preview--html-filename (org-file)
  "Generate HTML filename for ORG-FILE."
  (let* ((base-name (file-name-base org-file))
         (html-name (concat base-name ".html")))
    (expand-file-name html-name (org-html-preview--get-temp-directory))))

;;; Server Management

(defun org-html-preview--start-http-server ()
  "Start the HTTP server if not already running."
  (unless org-html-preview--server-running
    (let ((port (org-html-preview--find-available-port
                 (car org-html-preview-port-range)
                 (cadr org-html-preview-port-range))))
      (if port
          (progn
            ;; Copy static assets to temp directory
            (org-html-preview--copy-static-assets)
            (setq httpd-root (org-html-preview--get-temp-directory))
            (setq httpd-port port)
            (httpd-start)
            (setq org-html-preview--http-port port)
            (setq org-html-preview--server-running t)
            (message "org-html-preview: HTTP server started on port %d" port))
        (error "org-html-preview: Could not find available port for HTTP server")))))

(defun org-html-preview--start-websocket-server ()
  "Start the WebSocket server if not already running."
  (unless org-html-preview--ws-server
    (let ((port (org-html-preview--find-available-port
                 (car org-html-preview-websocket-port-range)
                 (cadr org-html-preview-websocket-port-range))))
      (if port
          (progn
            (setq org-html-preview--ws-server
                  (websocket-server
                   port
                   :host 'local
                   :on-open (lambda (ws)
                              (push ws org-html-preview--ws-clients)
                              (message "org-html-preview: WebSocket client connected"))
                   :on-close (lambda (ws)
                               (setq org-html-preview--ws-clients
                                     (delete ws org-html-preview--ws-clients))
                               (message "org-html-preview: WebSocket client disconnected"))
                   :on-error (lambda (_ws _type err)
                               (message "org-html-preview: WebSocket error: %s" err))))
            (setq org-html-preview--ws-port port)
            (message "org-html-preview: WebSocket server started on port %d" port))
        (error "org-html-preview: Could not find available port for WebSocket server")))))

(defun org-html-preview--stop-servers ()
  "Stop all preview servers."
  (interactive)
  ;; Stop HTTP server
  (when org-html-preview--server-running
    (httpd-stop)
    (setq org-html-preview--server-running nil)
    (setq org-html-preview--http-port nil)
    (message "org-html-preview: HTTP server stopped"))
  ;; Stop WebSocket server
  (when org-html-preview--ws-server
    (websocket-server-close org-html-preview--ws-server)
    (setq org-html-preview--ws-server nil)
    (setq org-html-preview--ws-port nil)
    (setq org-html-preview--ws-clients '())
    (message "org-html-preview: WebSocket server stopped")))

(defun org-html-preview--ensure-servers ()
  "Ensure both HTTP and WebSocket servers are running."
  (org-html-preview--start-http-server)
  (org-html-preview--start-websocket-server))

;;; HTML Export

(defun org-html-preview--copy-local-images ()
  "Copy local images referenced in the org buffer to the temp directory.
Returns an alist of (original-path . new-filename) for path rewriting."
  (let ((org-dir (file-name-directory (buffer-file-name)))
        (temp-dir (org-html-preview--get-temp-directory))
        (image-mappings '()))
    (save-excursion
      (goto-char (point-min))
      ;; Match file links: [[file:path]] or [[./path]]
      (while (re-search-forward "\\[\\[\\(?:file:\\)?\\([^]]+\\.\\(?:png\\|jpg\\|jpeg\\|gif\\|svg\\|webp\\|bmp\\)\\)\\]" nil t)
        (let* ((img-path (match-string 1))
               (abs-path (expand-file-name img-path org-dir))
               (img-name (file-name-nondirectory abs-path))
               (dest-path (expand-file-name img-name temp-dir)))
          (when (file-exists-p abs-path)
            (copy-file abs-path dest-path t)
            (push (cons img-path img-name) image-mappings)))))
    image-mappings))

(defun org-html-preview--rewrite-image-paths (html-content image-mappings)
  "Rewrite image paths in HTML-CONTENT using IMAGE-MAPPINGS."
  (let ((result html-content))
    (dolist (mapping image-mappings)
      (let ((original (car mapping))
            (new-name (cdr mapping)))
        ;; Replace src="original" with src="new-name"
        (setq result (replace-regexp-in-string
                      (regexp-quote original)
                      new-name
                      result t t))))
    result))

(defun org-html-preview--export-to-html ()
  "Export current org buffer to HTML with live reload support."
  (when (and (eq major-mode 'org-mode)
             (buffer-file-name))
    ;; Always copy static assets to ensure latest CSS/JS
    (org-html-preview--copy-static-assets)
    (let* ((org-file (buffer-file-name))
           (html-file (org-html-preview--html-filename org-file))
           (title (or (org-get-title) (file-name-base org-file)))
           ;; Copy images first and get the mappings
           (image-mappings (org-html-preview--copy-local-images))
           (org-html-content))
      ;; Export org to HTML body only
      (let ((org-export-show-temporary-export-buffer nil)
            (org-html-doctype "html5")
            (org-html-html5-fancy t)
            (org-html-head-include-default-style nil)
            (org-html-head-include-scripts nil)
            (org-html-preamble nil)
            (org-html-postamble nil)
            ;; Use MathJax for LaTeX rendering
            (org-html-with-latex 'mathjax))
        (setq org-html-content
              (org-export-as 'html nil nil t '(:body-only t))))
      ;; Rewrite image paths in the HTML content
      (setq org-html-content
            (org-html-preview--rewrite-image-paths org-html-content image-mappings))
      ;; Write the full HTML with template
      (let ((full-html (format org-html-preview--html-template
                               title
                               org-html-content
                               (or org-html-preview--ws-port 9901))))
        (with-temp-file html-file
          (insert full-html)))
      ;; Update file mapping
      (puthash org-file html-file org-html-preview--file-mapping)
      html-file)))

(defun org-html-preview--notify-clients ()
  "Send reload notification to all connected WebSocket clients."
  (let ((message (json-encode '((type . "reload")))))
    (dolist (client org-html-preview--ws-clients)
      (condition-case err
          (websocket-send-text client message)
        (error
         (message "org-html-preview: Failed to notify client: %s" err))))))

(defun org-html-preview--on-save ()
  "Hook function called when an org buffer is saved."
  (when (and org-html-preview-mode
             (eq major-mode 'org-mode))
    (org-html-preview--export-to-html)
    (org-html-preview--notify-clients)))

;;; Browser Integration

(defun org-html-preview--get-preview-url ()
  "Get the preview URL for current buffer."
  (when (and org-html-preview--http-port
             (buffer-file-name))
    (let ((html-file (org-html-preview--html-filename (buffer-file-name))))
      (format "http://localhost:%d/%s"
              org-html-preview--http-port
              (file-name-nondirectory html-file)))))

;;;###autoload
(defun org-html-preview-open ()
  "Open the preview in browser for current buffer."
  (interactive)
  (if (and org-html-preview--server-running
           (buffer-file-name))
      (let ((url (org-html-preview--get-preview-url)))
        (funcall org-html-preview-browser-function url)
        (message "org-html-preview: Opening %s" url))
    (if (not org-html-preview--server-running)
        (message "org-html-preview: Server not running. Enable org-html-preview-mode first.")
      (message "org-html-preview: Buffer has no file associated."))))

;;; Modeline

(defvar org-html-preview--mode-line-format
  '(:eval (org-html-preview--mode-line-string))
  "Mode line format for org-html-preview.")

(defun org-html-preview--mode-line-string ()
  "Return mode line string showing server status."
  (if org-html-preview--server-running
      (format " Preview[:%d]" org-html-preview--http-port)
    " Preview[off]"))

;;; Buffer Tracking

(defun org-html-preview--register-buffer ()
  "Register current buffer for preview tracking."
  (unless (member (current-buffer) org-html-preview--tracked-buffers)
    (push (current-buffer) org-html-preview--tracked-buffers)))

(defun org-html-preview--unregister-buffer ()
  "Unregister current buffer from preview tracking."
  (setq org-html-preview--tracked-buffers
        (delete (current-buffer) org-html-preview--tracked-buffers))
  ;; Clean up HTML file
  (when-let* ((org-file (buffer-file-name))
              (html-file (gethash org-file org-html-preview--file-mapping)))
    (when (file-exists-p html-file)
      (delete-file html-file))
    (remhash org-file org-html-preview--file-mapping))
  ;; Stop servers if no more tracked buffers
  (when (null org-html-preview--tracked-buffers)
    (org-html-preview--stop-servers)))

;;; Minor Mode

(defvar org-html-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-v o") #'org-html-preview-open)
    (define-key map (kbd "C-c C-v r") #'org-html-preview-refresh)
    (define-key map (kbd "C-c C-v s") #'org-html-preview-stop)
    map)
  "Keymap for `org-html-preview-mode'.")

;;;###autoload
(define-minor-mode org-html-preview-mode
  "Minor mode for live previewing org files as HTML in browser.

When enabled, saving the buffer will automatically export the org
file to HTML and refresh any connected browsers via WebSocket.

\\{org-html-preview-mode-map}"
  :lighter org-html-preview--mode-line-format
  :keymap org-html-preview-mode-map
  :group 'org-html-preview
  (if org-html-preview-mode
      (org-html-preview--enable)
    (org-html-preview--disable)))

(defun org-html-preview--enable ()
  "Enable org-html-preview-mode."
  (unless (eq major-mode 'org-mode)
    (setq org-html-preview-mode nil)
    (error "org-html-preview-mode only works with org-mode buffers"))
  (unless (buffer-file-name)
    (setq org-html-preview-mode nil)
    (error "org-html-preview-mode requires the buffer to be associated with a file"))
  ;; Ensure servers are running
  (org-html-preview--ensure-servers)
  ;; Register this buffer
  (org-html-preview--register-buffer)
  ;; Add save hook
  (add-hook 'after-save-hook #'org-html-preview--on-save nil t)
  ;; Initial export
  (org-html-preview--export-to-html)
  ;; Auto-open browser if configured
  (when org-html-preview-auto-open-browser
    (run-at-time 0.5 nil #'org-html-preview-open))
  (message "org-html-preview: Preview mode enabled (HTTP: %d, WS: %d)"
           org-html-preview--http-port
           org-html-preview--ws-port))

(defun org-html-preview--disable ()
  "Disable org-html-preview-mode."
  (remove-hook 'after-save-hook #'org-html-preview--on-save t)
  (org-html-preview--unregister-buffer)
  (message "org-html-preview: Preview mode disabled"))

;;; Interactive Commands

;;;###autoload
(defun org-html-preview-refresh ()
  "Manually refresh the preview."
  (interactive)
  (if org-html-preview-mode
      (progn
        (org-html-preview--export-to-html)
        (org-html-preview--notify-clients)
        (message "org-html-preview: Preview refreshed"))
    (message "org-html-preview: Preview mode is not active")))

;;;###autoload
(defun org-html-preview-stop ()
  "Stop all preview servers and disable preview mode in all buffers."
  (interactive)
  (dolist (buf org-html-preview--tracked-buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (org-html-preview-mode -1))))
  (org-html-preview--stop-servers)
  (message "org-html-preview: All servers stopped"))

;;;###autoload
(defun org-html-preview-status ()
  "Display the current status of the preview servers."
  (interactive)
  (if org-html-preview--server-running
      (message "org-html-preview: HTTP server on port %d, WebSocket on port %d, %d buffer(s) tracked"
               org-html-preview--http-port
               org-html-preview--ws-port
               (length org-html-preview--tracked-buffers))
    (message "org-html-preview: Servers not running")))

(provide 'org-html-preview)
;;; org-html-preview.el ends here
