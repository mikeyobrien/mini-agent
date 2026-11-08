;;;; eventd.lisp — always-on event bus daemon.
;;;; Long-running SBCL image: eventbus + chanreg (pluggable channels).
;;;;  - dispatcher: per-channel since-cursors, retries, backoff (deliveries.db)
;;;;  - heartbeat: eventd/beat liveness tick
;;;;  - stdin REPL: "topic json" per line to publish; "since <id> [glob]" dumps
;;;; Run:  sbcl --load src/eventd.lisp   (foreground)
;;;;       nohup sbcl --load src/eventd.lisp &  (background; pid in eventd.pid)

(load (merge-pathnames "eventbus.lisp" *load-truename*))
(load (merge-pathnames "chanreg.lisp" *load-truename*))
(eventbus:ensure-schema)
(chanreg:load-connectors)

(defpackage :eventd (:use :cl) (:import-from :eventbus #:publish #:since))
(in-package :eventd)

(defparameter *pid-file* (merge-pathnames "eventd.pid" (uiop:getcwd)))

;;; Heartbeat is a liveness tick, not an event. The 30s cadence proves the
;;; process is alive for monitors; real events flow the instant they happen
;;; (every publish writes straight through). Interval is env-tunable.
(defparameter *beat-interval*
  (parse-integer (or (uiop:getenv "EVENTD_BEAT_SECONDS") "30")))

;;; --- sqlite for delivery state -----------------------------------------------

(defparameter *dispatch-db* (merge-pathnames "deliveries.db" (uiop:getcwd)))
(defparameter *dispatch-poll-seconds*
  (parse-integer (or (uiop:getenv "EVENTD_DISPATCH_POLL_SECONDS") "2")))
(defparameter *dispatch-max-backoff*
  (parse-integer (or (uiop:getenv "EVENTD_DISPATCH_MAX_BACKOFF") "300")))

(defun ddb ()
  (let ((c (sqlite:connect *dispatch-db*)))
    (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
    (sqlite:execute-to-list c "PRAGMA journal_mode=WAL")
    c))

(defun ensure-deliveries-schema ()
  (let ((c (ddb)))
    (sqlite:execute-non-query c
      "CREATE TABLE IF NOT EXISTS deliveries (
         channel TEXT NOT NULL, event_id INTEGER NOT NULL,
         status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
         next_at INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (channel, event_id))")
    (sqlite:disconnect c)))

;;; --- delivery state: per-channel cursors + retries ----------------------------
;;; One table, every channel. (channel, event_id) is the unit: 'sent' = done,
;;; 'dead' = gave up after *max-attempts*, 'claimed'/'pending' + next_at =
;;; awaiting (re)delivery with backoff.
;;; Each channel owns its own replay point; a restart resumes all independently.

(defmacro with-ddb ((conn) &body body)
  `(let ((,conn (ddb)))
     (unwind-protect (progn ,@body) (sqlite:disconnect ,conn))))

(defun channel-cursor (name)
  "Highest event id channel NAME has a row for, any status — its since-watermark.
   Pending/dead rows count: a failed tail event must come back only through
   due-claims (honoring next_at), never as 'fresh' on the next tick."
  (with-ddb (c)
    (or (sqlite:execute-single c
          "SELECT MAX(event_id) FROM deliveries WHERE channel=?" name)
        0)))

(defun claim (name event-id)
  "Record an attempt; returns attempts count after the claim."
  (with-ddb (c)
    (sqlite:execute-non-query c
      "INSERT INTO deliveries(channel,event_id,status,attempts,next_at)
       VALUES (?1,?2,'claimed',1,0)
       ON CONFLICT(channel,event_id) DO UPDATE SET
         status='claimed', attempts=deliveries.attempts+1"
      name event-id)
    (sqlite:execute-single c
      "SELECT attempts FROM deliveries WHERE channel=? AND event_id=?" name event-id)))

(defun mark-status (name event-id status)
  (with-ddb (c)
    (sqlite:execute-non-query c
      "UPDATE deliveries SET status=? WHERE channel=? AND event_id=?"
      status name event-id)))

(defun mark-sent (name event-id) (mark-status name event-id "sent"))

(defparameter *max-attempts* 50)

(defun requeue (name event-id attempts)
  "Exponential backoff, capped; poison events marked 'dead' after MAX-ATTEMPTS."
  (if (and attempts (>= attempts *max-attempts*))
      (progn
        (format *error-output* "dispatch ~a: event ~a retired after ~a attempts~%"
                name event-id attempts)
        (mark-status name event-id "dead"))
      (let ((delay (min (* 2 (expt 2 (min (or attempts 1) 16)))
                        *dispatch-max-backoff*)))
        (with-ddb (c)
          (sqlite:execute-non-query c
            "UPDATE deliveries SET status='pending',next_at=? WHERE channel=? AND event_id=?"
            (+ (get-universal-time) delay) name event-id)))))

(defun due-claims (name now)
  "Ids this channel may attempt now: claimed-then-crashed or backoff expired.
   Bounded per tick so one flooding channel cannot starve the rest."
  (with-ddb (c)
    (mapcar #'first
            (sqlite:execute-to-list c
              "SELECT event_id FROM deliveries
               WHERE channel=? AND status IN ('pending','claimed') AND next_at<=?
               ORDER BY event_id LIMIT 100"
              name now))))

(defun deliver (channel event)
  "One attempt at EVENT on CHANNEL: sent, or requeued with backoff."
  (let* ((name (chanreg:channel-name channel))
         (id (getf event :id))
         (attempts (claim name id)))
    (if (ignore-errors
          (funcall (chanreg:channel-send-fn channel)
                   id (getf event :ts) (getf event :topic) (getf event :data)))
        (mark-sent name id)
        (requeue name id attempts))))

(defun dispatch-channel (channel)
  "One tick for one channel: due retries, then events past its cursor (the
   two never overlap - every retry id is at or below the cursor). Never
   raises: a broken connector degrades to backoff, not a dead daemon."
  (handler-case
      (let ((name (chanreg:channel-name channel)))
        (dolist (id (due-claims name (get-universal-time)))
          (let ((event (eventbus:get-event id)))
            (if event
                (deliver channel event)
                (mark-status name id "dead"))))   ; bus rebuilt under it
        (dolist (event (eventbus:since (channel-cursor name)
                                       (chanreg:channel-poll-glob channel)))
          (deliver channel event)))
    (error (e)
      (format *error-output* "dispatch ~a: ~a~%" (chanreg:channel-name channel) e))))

(defun dispatcher ()
  "Delivers on every publish in this image; polls for outside writers and
   due retries every *dispatch-poll-seconds*."
  (loop
    (let ((seen (eventbus:publish-count)))
      (dolist (ch (chanreg:all-channels))
        (dispatch-channel ch))
      (eventbus:await-publish seen *dispatch-poll-seconds*))))

(defun heartbeat ()
  "Liveness tick, forever. Nothing escapes it."
  (loop
    (handler-case (publish "eventd/beat" (eventbus:dict "ts" (get-universal-time)))
      (serious-condition (e) (format *error-output* "heartbeat: ~a~%" e)))
    (sleep *beat-interval*)))

(defun repl-line (line)
  (let* ((sp (position #\Space line))
         (cmd (if sp (subseq line 0 sp) line))
         (rest (when sp (subseq line (1+ sp)))))
    (cond
      ((string= cmd "since")
       (let* ((parts (and rest (uiop:split-string rest)))
              (id (parse-integer (or (first parts) "0")))
              (glob (second parts)))
         (dolist (e (eventbus:since id glob))
           (format t "~a~%" (com.inuoe.jzon:stringify
                              (eventbus:dict "id" (getf e :id) "topic" (getf e :topic)
                                             "data" (getf e :data)))))))
      (t (publish cmd (and rest (com.inuoe.jzon:parse rest)))
         (format t "ok~%")))))

(defun repl ()
  "stdin commands until EOF. A bad line is reported, never fatal."
  (loop for line = (read-line *standard-input* nil nil)
        while line
        do (handler-case (repl-line line)
             (error (e) (format t "error: ~a~%" e)))
           (finish-output)))

(defun spawn (name fn)
  "Thread running FN; under --script an escaped error would exit the daemon."
  (sb-thread:make-thread
   (lambda ()
     (handler-case (funcall fn)
       (error (e) (format *error-output* "~a: died: ~a~%" name e))))
   :name name))

(defun main ()
  (with-open-file (f *pid-file* :direction :output :if-exists :supersede)
    (format f "~a~%" (sb-posix:getpid)))
  (ensure-deliveries-schema)
  (format t "eventd up; pid in ~a; channels: ~{~a~^, ~}; stdin: \"topic {json}\" | since <id> [glob]~%"
          *pid-file* (mapcar #'chanreg:channel-name (chanreg:all-channels)))
  (finish-output)
  (chanreg:run-boot-hooks)
  (spawn "dispatcher" #'dispatcher)
  (dolist (ch (chanreg:all-channels))
    (when (chanreg:channel-start-fn ch)
      (spawn (format nil "~a-start" (chanreg:channel-name ch))
             (chanreg:channel-start-fn ch))))
  (spawn "repl" #'repl)               ; returns at stdin EOF (daemon mode)
  (heartbeat))

(defun stop ()
  (let ((pid (with-open-file (f *pid-file* :direction :input) (parse-integer (read-line f)))))
    (sb-posix:kill pid 15)))


;; EVENTD_NO_MAIN=1: load definitions only (tests).
(unless (uiop:getenv "EVENTD_NO_MAIN") (main))
