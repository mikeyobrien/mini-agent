;;;; echo-responder.lisp -- consumer on telegram/inbound, replies via the bus.
;;;; Not a channel: a boot-hook thread that tails telegram/inbound and echoes
;;;; each text back to its chat through telegram/outbound. Idempotent per
;;;; update_id via its own cursor row in deliveries.db (channel='echo').

(require :uiop)

(defpackage :echo-responder
  (:use :cl)
  (:export #:boot))

(in-package :echo-responder)

(defparameter *poll-seconds* 2)
(defparameter *db* nil)              ; set at boot: deliveries.db path
(defparameter *cursor* 0)            ; in-memory watermark, seeded from db

(defun jget (h k) (and (hash-table-p h) (gethash k h)))

(defun seen-p (event-id)
  (let ((c (sqlite:connect *db*)))
    (unwind-protect
         (progn
           (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
           (let ((stmt (sqlite:prepare-statement c
                         "SELECT 1 FROM deliveries WHERE channel='echo' AND event_id=? AND status='sent'")))
             (sqlite:bind-parameter stmt 1 event-id)
             (prog1 (and (sqlite:step-statement stmt) t)
               (sqlite:finalize-statement stmt))))
      (sqlite:disconnect c))))

(defun mark (event-id)
  (let ((c (sqlite:connect *db*)))
    (unwind-protect
         (progn
           (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
           (sqlite:execute-non-query c
             "INSERT INTO deliveries(channel,event_id,status,attempts,next_at)
              VALUES ('echo',?,'sent',1,0)
              ON CONFLICT(channel,event_id) DO UPDATE SET status='sent'"
             event-id))
      (sqlite:disconnect c))))

(defun reply (chat-id text)
  (eventbus:publish "telegram/outbound"
                    (let ((h (make-hash-table :test 'equal)))
                      (setf (gethash "chat_id" h) chat-id
                            (gethash "text" h) text)
                      h)))

(defun handle (event)
  (let* ((id (getf event :id))
         (data (getf event :data))
         (text (jget data "text"))
         (chat (jget data "chat_id")))
    (when (and text chat (not (seen-p id)))
      ;; Echo with provenance; skip our own outbound echoes (they arrive as
      ;; inbound only if someone re-feeds them, so no loop risk in practice).
      (reply chat (format nil "~a" text))
      (mark id)
      (setf *cursor* (max *cursor* id)))))

(defun seed-cursor ()
  ;; Start AFTER history: respond only to messages from now on.
  (let ((c (sqlite:connect *db*)))
    (unwind-protect
         (let ((stmt (sqlite:prepare-statement c
                       "SELECT COALESCE(MAX(event_id),0) FROM deliveries WHERE channel='echo'")))
           (sqlite:step-statement stmt)
           (setf *cursor* (or (sqlite:statement-column-value stmt 0) 0))
           (sqlite:finalize-statement stmt))
      (sqlite:disconnect c))))

(defun loop! ()
  (loop
    (handler-case
        (let ((events (eventbus:since *cursor* "telegram/inbound")))
          (dolist (e events) (handle e))
          (let ((last (and events (getf (car (last events)) :id))))
            (when (and last (> last *cursor*)) (setf *cursor* last))))
      (error (e)
        (format *error-output* "echo-responder: ~a~%" e)
        (sleep 5)))
    (sleep *poll-seconds*)))

(defun boot ()
  (setf *db* (merge-pathnames "deliveries.db" (uiop:getcwd)))
  (seed-cursor)
  (format *error-output* "echo-responder: up, cursor=~a~%" *cursor*)
  (loop!))

;; self-register as a boot hook when loaded from channels.d/
(when (find-package :chanreg)
  (push #'echo-responder:boot
        (symbol-value (find-symbol "*BOOT-HOOKS*" :chanreg))))
