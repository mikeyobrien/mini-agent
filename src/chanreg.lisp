;;;; chanreg.lisp -- the channel seam: registry + dispatcher state, no channel.
;;;;
;;;; A channel is (name poll-glob send-fn). The dispatcher (eventd) owns
;;;; cursors, retries, backoff; connectors own format translation only.
;;;; Connectors self-register by loading files from channels.d/ -- adding a
;;;; channel is a file drop, never a core edit.

(require :uiop)

(defpackage :chanreg
  (:use :cl)
  (:import-from :uiop #:getenv)
  (:export #:channel #:channel-name #:channel-poll-glob #:channel-send-fn
           #:channel-start-fn #:*boot-hooks*
           #:register #:find-channel #:all-channels #:run-boot-hooks
           #:load-connectors #:connector-dir))

(in-package :chanreg)

(defvar *source-dir*
  (make-pathname :defaults (or *load-truename* *default-pathname-defaults*)
                 :name nil :type nil)
  "Directory containing this file, captured at load time.")

(defvar *registry* (make-hash-table :test 'equal)
  "name -> CHANNEL. Registration replaces any prior channel of that name.")

(defstruct channel
  name
  poll-glob
  send-fn
  start-fn)   ; optional (lambda) run in its own thread at daemon boot

(defun register (name poll-glob send-fn &optional start-fn)
  "Idempotent by name: re-registration replaces (hot-reload friendly)."
  (setf (gethash (string name) *registry*)
        (make-channel :name (string name)
                      :poll-glob poll-glob
                      :send-fn send-fn
                      :start-fn start-fn)))

(defun find-channel (name)
  (gethash (string name) *registry*))

(defun all-channels ()
  (loop for v being the hash-values of *registry* collect v))

(defvar *boot-hooks* nil
  "List of zero-arg thunks run in their own threads after daemon boot.
   Consumers (responders, bridges) push onto this in their connector file;
   they see the bus without being channels.")

(defun run-boot-hooks ()
  (dolist (thunk (reverse *boot-hooks*))
    (ignore-errors
      (sb-thread:make-thread thunk :name "chanreg-boot-hook"))))

(defun connector-dir ()
  "channels.d/ beside src/ (repo root), $CHANREG_DIR, or cwd."
  (or (and (getenv "CHANREG_DIR") (pathname (getenv "CHANREG_DIR")))
      (let ((repo-root (make-pathname :directory
                                      (butlast (pathname-directory *source-dir*)))))
        (merge-pathnames "channels.d/" repo-root))))

(defun load-connectors (&optional (dir (connector-dir)))
  "Load every .lisp in dir. One broken connector must not kill the daemon:
   failures are logged and skipped, never fatal."
  (when (probe-file dir)
    (dolist (f (directory (merge-pathnames "*.lisp" dir)))
      (handler-case (load f)
        (error (e) (format *error-output* "chanreg: ~a failed: ~a~%" f e))))))
