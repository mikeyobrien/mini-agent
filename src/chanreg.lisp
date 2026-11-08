;;;; chanreg.lisp -- the channel seam: registry + dispatcher state, no channel.
;;;;
;;;; A channel is (name poll-glob send-fn). The dispatcher (eventd) owns
;;;; cursors, retries, backoff; connectors own format translation only.
;;;; Connectors self-register by loading files from channels.d/ -- adding a
;;;; channel is a file drop, never a core edit. Files there are loaded after
;;;; eventbus and chanreg, so they may name eventbus:/chanreg: symbols directly.

(require :uiop)

(defpackage :chanreg
  (:use :cl)
  (:import-from :uiop #:getenv)
  (:export #:channel #:channel-name #:channel-poll-glob #:channel-send-fn
           #:channel-start-fn
           #:register #:find-channel #:all-channels
           #:add-boot-hook #:run-boot-hooks
           #:load-connectors #:connector-dir #:repo-root))

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
  "Alist name -> zero-arg thunk, in registration order. Each runs in its own
   thread after daemon boot. Consumers (responders, bridges) add themselves
   from their connector file; they see the bus without being channels.")

(defun add-boot-hook (name thunk)
  "Idempotent by name, like REGISTER: reloading a file replaces its hook."
  (let ((cell (assoc name *boot-hooks* :test #'string=)))
    (if cell
        (setf (cdr cell) thunk)
        (setf *boot-hooks* (append *boot-hooks* (list (cons name thunk)))))))

(defun run-boot-hooks ()
  ;; Under --script an unhandled error in any thread exits the daemon: a
  ;; failing hook is logged and ends alone.
  (loop for (name . thunk) in *boot-hooks*
        do (let ((name name) (thunk thunk))
             (sb-thread:make-thread
              (lambda ()
                (handler-case (funcall thunk)
                  (error (e) (format *error-output* "~a: hook died: ~a~%" name e))))
              :name name))))

(defun repo-root ()
  "The checkout this file was loaded from (src/..)."
  (make-pathname :directory (butlast (pathname-directory *source-dir*))
                 :defaults *source-dir*))

(defun connector-dir ()
  "$CHANREG_DIR, else channels.d/ in the repo root."
  (or (and (getenv "CHANREG_DIR") (pathname (getenv "CHANREG_DIR")))
      (merge-pathnames "channels.d/" (repo-root))))

(defun load-connectors (&optional (dir (connector-dir)))
  "Load every .lisp in dir. One broken connector must not kill the daemon:
   failures are logged and skipped, never fatal."
  (when (probe-file dir)
    (dolist (f (directory (merge-pathnames "*.lisp" dir)))
      (handler-case (load f)
        (error (e) (format *error-output* "chanreg: ~a failed: ~a~%" f e))))))
