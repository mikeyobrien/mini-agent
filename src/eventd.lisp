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
(in-package :eventd)(defparameter *pid-file* (merge-pathnames "eventd.pid" (uiop:getcwd)))
(defparameter *log* *standard-output*)

;;; Heartbeat is a liveness tick, not an event. The 30s cadence proves the
;;; process is alive for monitors; real events flow the instant they happen
;;; (every publish writes straight through). Interval is env-tunable.
(defparameter *beat-interval*
  (parse-integer (or (uiop:getenv "EVENTD_BEAT_SECONDS") "30")))

;;; --- sqlite for delivery state -----------------------------------------------

(require :sqlite)

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
;;; 'claimed'/'pending' + next_at = awaiting (re)delivery with backoff.
;;; Each channel owns its own replay point; a restart resumes all independently.

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

(defmacro with-ddb ((conn) &body body)
  `(let ((,conn (ddb)))
     (unwind-protect (progn ,@body) (sqlite:disconnect ,conn))))

(defun channel-cursor (name)
  "Highest sent/claimed event id for channel NAME — its since-watermark."
  (with-ddb (c)
    (let ((stmt (sqlite:prepare-statement c
                  "SELECT COALESCE(MAX(event_id),0) FROM deliveries
                   WHERE channel=? AND status IN ('sent','claimed')")))
      (sqlite:bind-parameter stmt 1 name)
      (sqlite:step-statement stmt)
      (let ((v (sqlite:statement-column-value stmt 0)))
        (sqlite:finalize-statement stmt)
        (or v 0)))))

(defun claim (name event-id)
  "Record an attempt; returns attempts count after the claim."
  (with-ddb (c)
    (sqlite:execute-non-query c
      "INSERT INTO deliveries(channel,event_id,status,attempts,next_at)
       VALUES (?1,?2,'claimed',1,0)
       ON CONFLICT(channel,event_id) DO UPDATE SET
         status='claimed', attempts=deliveries.attempts+1"
      name event-id)
    (let ((stmt (sqlite:prepare-statement c
                  "SELECT attempts FROM deliveries WHERE channel=? AND event_id=?")))
      (sqlite:bind-parameter stmt 1 name)
      (sqlite:bind-parameter stmt 2 event-id)
      (sqlite:step-statement stmt)
      (let ((v (sqlite:statement-column-value stmt 0)))
        (sqlite:finalize-statement stmt)
        (or v 1)))))

(defun mark-sent (name event-id)
  (with-ddb (c)
    (sqlite:execute-non-query c
      "UPDATE deliveries SET status='sent' WHERE channel=? AND event_id=?"
      name event-id)))

(defun requeue (name event-id attempts)
  "Exponential backoff, capped: 2^n seconds."
  (let ((delay (min (* 2 (expt 2 (min (or attempts 1) 16)))
                    *dispatch-max-backoff*)))
    (with-ddb (c)
      (sqlite:execute-non-query c
        "UPDATE deliveries SET status='pending',next_at=? WHERE channel=? AND event_id=?"
        (+ (get-universal-time) delay) name event-id))))

(defun due-claims (name now)
  "Ids this channel may attempt now: claimed-then-crashed or backoff expired.
   Bounded per tick so one flooding channel cannot starve the rest."
  (with-ddb (c)
    (let ((stmt (sqlite:prepare-statement c
                  "SELECT event_id FROM deliveries
                   WHERE channel=? AND status IN ('pending','claimed') AND next_at<=?
                   LIMIT 100"))
          acc)
      (sqlite:bind-parameter stmt 1 name)
      (sqlite:bind-parameter stmt 2 now)
      (loop while (sqlite:step-statement stmt)
            do (push (sqlite:statement-column-value stmt 0) acc))
      (sqlite:finalize-statement stmt)
      (nreverse acc))))

(defun dispatch-channel (channel)
  "One tick for one channel. Never raises: a broken connector degrades to
   backoff, it cannot take the daemon down."
  (handler-case
      (let* ((name (chanreg:channel-name channel))
             (now (get-universal-time))
             (retries (due-claims name now))
             (cursor (channel-cursor name))
             (retries-set (when retries (nreverse (copy-list retries))))
             (fresh (remove-if (lambda (id) (member id retries))
                               (mapcar #'(lambda (e) (getf e :id))
                                       (eventbus:since cursor
                                                      (chanreg:channel-poll-glob channel))))))
        (declare (ignore retries-set))
        (dolist (id (append retries fresh))
          ;; Re-fetch the single event: id may have been backoff-queued long ago.
          (let ((event (find id (eventbus:since (1- id)) :key #'(lambda (e) (getf e :id)))))
            (when event
              (let ((attempts (claim name id)))
                (if (ignore-errors
                      (funcall (chanreg:channel-send-fn channel)
                               id (getf event :ts) (getf event :topic) (getf event :data)))
                    (mark-sent name id)
                    (requeue name id attempts)))))))
    (error (e)
      (format *error-output* "dispatch ~a: ~a~%" (chanreg:channel-name channel) e))))

(defun dispatcher ()
  (loop
    (dolist (ch (chanreg:all-channels))
      (dispatch-channel ch))
    (sleep *dispatch-poll-seconds*)))

(defun heartbeat ()
  (loop
    (publish "eventd/beat" (list :ts (get-universal-time)))
    (sleep *beat-interval*)))

(defun repl ()
  (loop
    (let ((line (read-line *standard-input* nil nil)))
      (unless line (return))
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
                                  (list :id (getf e :id) :topic (getf e :topic)
                                        :data (getf e :data)))))))
          (t (publish cmd (and rest (com.inuoe.jzon:parse rest)))
             (format t "ok~%")))))))

(defun main ()
  (with-open-file (f *pid-file* :direction :output :if-exists :supersede)
    (format f "~a~%" (sb-posix:getpid)))
  (ensure-deliveries-schema)
  (format t "eventd up; pid in ~a; channels: ~{~a~^, ~}; stdin: \"topic {json}\" | since <id> [glob]~%"
          *pid-file* (mapcar #'chanreg:channel-name (chanreg:all-channels)))
  (let ((hb (sb-thread:make-thread #'heartbeat :name "heartbeat"))
        (dp (sb-thread:make-thread #'dispatcher :name "dispatcher"))
        (starts (remove-if-not #'chanreg:channel-start-fn (chanreg:all-channels))))
    (dolist (ch starts)
      (ignore-errors
        (sb-thread:make-thread (chanreg:channel-start-fn ch)
                               :name (format nil "~a-start" (chanreg:channel-name ch)))))
    (repl)
    ;; stdin exhausted (daemon/redirect mode): keep serving beats + bus forever
    (sb-thread:join-thread hb)
    (sb-thread:join-thread dp)))

(defun stop ()
  (let ((pid (with-open-file (f *pid-file* :direction :input) (parse-integer (read-line f)))))
    (sb-posix:kill pid 15)))


(main)
