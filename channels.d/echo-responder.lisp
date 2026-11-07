;;;; echo-responder.lisp -- consumer on telegram/inbound, replies via the bus.
;;;; Not a channel: a boot-hook thread that tails telegram/inbound and echoes
;;;; each text back to its chat through telegram/outbound.
;;;;
;;;; Idempotency is by TELEGRAM update_id (the natural key of an update),
;;;; stored in echo_seen(update_id) with a UNIQUE index -- re-delivered or
;;;; re-injected events never double-reply, even across bus rebuilds.

(require :uiop)

(defpackage :echo-responder
  (:use :cl)
  (:export #:boot))

(in-package :echo-responder)

(defparameter *poll-seconds* 2)
(defparameter *db* nil)              ; deliveries.db path, set at boot
(defparameter *cursor* 0)            ; bus watermark (event id), in-memory

(defun jget (h k) (and (hash-table-p h) (gethash k h)))

(defun ensure-schema ()
  (let ((c (sqlite:connect *db*)))
    (unwind-protect
         (progn
           (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
           (sqlite:execute-non-query c
             "CREATE TABLE IF NOT EXISTS echo_seen (
                update_id INTEGER PRIMARY KEY,
                ts TEXT DEFAULT (datetime('now')))")
           (sqlite:execute-non-query c
             "CREATE INDEX IF NOT EXISTS i_echo_ts ON echo_seen(ts)"))
      (sqlite:disconnect c))))

(defun seen-p (update-id)
  (and update-id
       (let ((c (sqlite:connect *db*)))
         (unwind-protect
              (let ((stmt (sqlite:prepare-statement c
                            "SELECT 1 FROM echo_seen WHERE update_id=?")))
                (sqlite:bind-parameter stmt 1 update-id)
                (prog1 (and (sqlite:step-statement stmt) t)
                  (sqlite:finalize-statement stmt)))
           (sqlite:disconnect c)))))

(defun mark (update-id)
  (when update-id
    (let ((c (sqlite:connect *db*)))
      (unwind-protect
           (progn
             (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
             (sqlite:execute-non-query c
               "INSERT OR IGNORE INTO echo_seen(update_id) VALUES (?)" update-id))
        (sqlite:disconnect c)))))

(defun reply (chat-id text)
  (eventbus:publish "telegram/outbound"
                    (let ((h (make-hash-table :test 'equal)))
                      (setf (gethash "chat_id" h) chat-id
                            (gethash "text" h) text)
                      h)))

(defun handle (event)
  (let* ((data (getf event :data))
         (update-id (jget data "update_id"))
         (text (jget data "text"))
         (chat (jget data "chat_id")))
    ;; No update_id (synthetic/manual inject): still reply, but nothing to
    ;; dedupe on -- accept the replay risk, it is test traffic by definition.
    ;; Mirror only explicit "echo ..." - plain text now goes to the agent.
    (when (and text chat (uiop:string-prefix-p "echo " text)
               (not (seen-p update-id)))
      (reply chat (subseq text 5))
      (mark update-id))))

(defun seed-cursor ()
  "Start at the bus tail: respond only to inbound from now on. The echo_seen
   table carries idempotency across restarts; the bus cursor does not persist."
  (setf *cursor* (eventbus:max-id "telegram/inbound")))

(defun loop! ()
  (loop
    (handler-case
        (progn
          (let ((events (eventbus:since *cursor* "telegram/inbound")))
            (dolist (e events) (handle e))
            (let ((last (and events (getf (car (last events)) :id))))
              (when (and last (> last *cursor*)) (setf *cursor* last)))))
      (error (e)
        (format *error-output* "echo-responder: ~a~%" e)
        (sleep 5)))
    (sleep *poll-seconds*)))

(defun boot ()
  (setf *db* (merge-pathnames "deliveries.db" (uiop:getcwd)))
  (ensure-schema)
  (seed-cursor)
  (format *error-output* "echo-responder: up, bus-cursor=~a~%" *cursor*)
  (loop!))

;; self-register as a boot hook when loaded from channels.d/
(when (find-package :chanreg)
  (push #'echo-responder:boot
        (symbol-value (find-symbol "*BOOT-HOOKS*" :chanreg))))
