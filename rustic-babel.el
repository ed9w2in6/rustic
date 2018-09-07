;;; rustic-babel.el --- Org babel facilities for cargo -*-lexical-binding: t-*-

;;; Commentary:

;; Async org-babel execution using cargo.  Building and running is seperated
;; into two processes, as it's easier to get the output for the result of the
;; current source block.

;;; Code:

(require 'org)
(require 'ob)
(require 'ob-eval)
(require 'ob-ref)
(require 'ob-core)

(require 'rustic-cargo)
(require 'rustic-compile)

(add-to-list 'org-babel-tangle-lang-exts '("rustic" . "rs"))

(defcustom rustic-babel-display-compilation-buffer nil
  "Whether to display compilation buffer."
  :type 'boolean
  :group 'rustic-babel)

(defcustom rustic-babel-format-src-block t
  "Whether to format a src block automatically after successful execution."
  :type 'boolean
  :group 'rustic-babel)

(defcustom rustic-babel-display-spinner t
  "Display spinner, that indicates a babel process is running."
  :type 'boolean
  :group 'rustic-babel)

(defvar rustic-babel-buffer-name '((:default . "*rust-babel*")))

(defvar rustic-babel-process-name "rustic-babel-process"
  "Process name for org-babel rust compilation processes.")

(defvar rustic-babel-compilation-buffer-name "*rustic-babel-compilation-buffer*"
  "Buffer name for org-babel rust compilation process buffers.")

(defvar rustic-babel-dir nil
  "Holds the latest rust babel project directory.")

(defvar rustic-babel-src-location nil
  "Marker, holding location of last evaluated src block.")

(defvar rustic-babel-params nil
  "Babel parameters.")

(defvar rustic-babel-spinner nil)

(defun rustic-babel-eval (dir)
  "Start a rust babel compilation process in directory DIR."
  (let* ((err-buff (get-buffer-create rustic-babel-compilation-buffer-name))
         (default-directory dir)
         (coding-system-for-read 'binary)
         (process-environment
          (nconc
           (list
            (format "TERM=%s" "ansi")
            (format "RUST_BACKTRACE=%s" rustic-compile-backtrace))
           process-environment))
         (params '("cargo" "build"))
         (inhibit-read-only t))
    (with-current-buffer err-buff
      (erase-buffer)
      (setq-local default-directory dir)
      (rustic-compilation-mode))
    (when rustic-babel-display-compilation-buffer
      (display-buffer err-buff))
    (make-process
     :name rustic-babel-process-name
     :buffer err-buff
     :command params
     :filter #'rustic-compilation-filter
     :sentinel #'rustic-babel-build-sentinel)))

(defun rustic-babel-build-sentinel (proc _output)
  "Sentinel for rust babel compilation process PROC.
If `rustic-babel-format-src-block' is t, format src-block after successful
execution with rustfmt."
  (let ((proc-buffer (process-buffer proc))
        (inhibit-read-only t))
    (if (zerop (process-exit-status proc))
        (let* ((default-directory rustic-babel-dir))
          (unless rustic-babel-display-compilation-buffer
            (kill-buffer proc-buffer))

          ;; format babel block
          (when rustic-babel-format-src-block
            (let ((babel-body
                   (org-element-property :value (org-element-at-point)))
                  (proc
                   (make-process :name "rustic-babel-format"
                                 :buffer "rustic-babel-format-buffer"
                                 :command `(,rustic-rustfmt-bin)
                                 :filter #'rustic-compilation-filter
                                 :sentinel #'rustic-babel-format-sentinel)))
              (while (not (process-live-p proc))
                (sleep-for 0.01))
              (process-send-string proc babel-body)
              (process-send-eof proc)
              (while (eq (process-status proc) 'run)
                (sit-for 0.1))))

          ;; run project
          (let* ((err-buff (get-buffer-create rustic-babel-compilation-buffer-name))
                 (dir default-directory)
                 (coding-system-for-read 'binary)
                 (process-environment
                  (nconc
                   (list
                    (format "TERM=%s" "ansi")
                    (format "RUST_BACKTRACE=%s" rustic-compile-backtrace))
                   process-environment))
                 (params '("cargo" "run" "--quiet"))
                 (inhibit-read-only t))
            (with-current-buffer err-buff
              (erase-buffer)
              (setq-local default-directory dir)
              (rustic-compilation-mode))
            (when rustic-babel-display-compilation-buffer
              (display-buffer err-buff))
            (make-process
             :name rustic-babel-process-name
             :buffer err-buff
             :command params
             :filter #'rustic-compilation-filter
             :sentinel #'rustic-babel-run-sentinel)))
      (with-rustic-spinner rustic-babel-spinner nil nil)
      (pop-to-buffer proc-buffer))))

(defun rustic-babel-run-sentinel (proc _output)
  "Sentinel for babel project execution."
  (let ((proc-buffer (process-buffer proc)))
    (if (zerop (process-exit-status proc))
        (let ((marker rustic-babel-src-location)
              (result-params (list (cdr (assq :results rustic-babel-params))))
              result)
          (with-current-buffer proc-buffer
            (setq result (buffer-string)))
          ;; update result block
          (with-current-buffer (marker-buffer marker)
            (goto-char marker)
            (org-babel-remove-result rustic-info)
            (org-babel-insert-result result result-params rustic-info))
          (kill-buffer proc-buffer))
      (pop-to-buffer proc-buffer))
    (with-rustic-spinner rustic-babel-spinner nil nil)))

(defun rustic-babel-format-sentinel (proc output)
  "This sentinel is used by the process `rustic-babel-format', that runs
after successful compilation."
  (let ((proc-buffer (process-buffer proc))
        (marker rustic-babel-src-location))
    (save-excursion
      (with-current-buffer proc-buffer
        (when (string-match-p "^finished" output)
          (with-current-buffer (marker-buffer marker)
            (goto-char marker)
            (org-babel-update-block-body
             (with-current-buffer "rustic-babel-format-buffer"
               (buffer-string)))))))
    (kill-buffer "rustic-babel-format-buffer")))

(defun rustic-babel-generate-project (&optional expand)
  "Create rust project in `org-babel-temporary-directory'.
Return full path if EXPAND is t."
  (let* ((default-directory org-babel-temporary-directory)
         (dir (make-temp-file-internal "cargo" 0 "" nil)))
    (shell-command-to-string (format "cargo new %s --bin --quiet" dir))
    (if expand
        (concat (expand-file-name dir) "/")
      dir)))

(defun rustic-babel-project ()
  "In order to reduce the execution time when the project has
dependencies, the project name is stored as a text property in the
header of the org-babel block to check if the project already exists
in `org-babel-temporary-directory'.  If the project exists, reuse it.
Otherwise create it with `rustic-babel-generate-project'."
  (let* ((beg (org-babel-where-is-src-block-head))
         (end (save-excursion (goto-char beg)
                              (line-end-position)))
         (line (buffer-substring beg end)))
    (let* ((project (symbol-name (get-text-property 0 'project line)))
           (path (concat org-babel-temporary-directory "/" project "/")))
      (if (file-directory-p path)
          (progn
            (put-text-property beg end 'project (make-symbol project))
            project)
        (let ((new (rustic-babel-generate-project)))
          (put-text-property beg end 'project (make-symbol new))
          new)))))

(defun rustic-babel-cargo-toml (dir params)
  "Append crates to Cargo.toml.
Use org-babel parameter crates from PARAMS and add them to the project in
directory DIR."
  (let ((crates (cdr (assq :crates params)))
        (toml (expand-file-name "Cargo.toml" dir))
        (str ""))
    (dolist (crate crates)
      (setq str (concat str (car crate) " = " "\"" (cdr crate) "\"" "\n")))
    (setq str (concat "[dependencies]\n" str) )
    (with-temp-file toml
      (insert-file-contents toml nil)
      (let ((s (nth 0 (split-string (buffer-string) "\\[dependencies]"))))
        (erase-buffer)
        (insert s)
        (insert str)))))

(defun org-babel-execute:rustic (body params)
  "Execute a block of Rust code with org-babel."
  (when-let* ((p (process-live-p (get-process rustic-babel-process-name))))
    (rustic-process-kill-p p))
  (let* ((default-directory org-babel-temporary-directory)
         (project (rustic-babel-project))
         (dir (setq rustic-babel-dir (expand-file-name project)))
         (main (expand-file-name "main.rs" (concat dir "/src"))))
    (rustic-babel-cargo-toml dir params)
    (setq rustic-info (org-babel-get-src-block-info))
    (setq rustic-babel-params params)

    (with-rustic-spinner rustic-babel-spinner
      (make-spinner rustic-spinner-type t 10)
      '(rustic-babel-spinner (":Executing " (:eval (spinner-print rustic-babel-spinner))))
      (spinner-start rustic-babel-spinner))

    (let ((default-directory dir))
      (write-region
       (concat "#![allow(non_snake_case)]\n" body) nil main nil 0)
      (rustic-babel-eval dir)
      (setq rustic-babel-src-location
            (set-marker (make-marker) (point) (current-buffer)))
      project)))

(provide 'rustic-babel)
;;; rustic-babel.el ends here
