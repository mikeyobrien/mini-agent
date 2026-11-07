;;;; eventbus.lisp — the event bus, in the same language as everything else.
;;;; Schema contract: events(id, ts, topic, payload-json). Any sqlite client speaks it.

(eval-when (:load-toplevel :execute)
  (unless (find-package :sqlite)
    (let ((setup (or (probe-file (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname)))
                     (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))))
      (unless setup (error "need quicklisp at ~/.quicklisp or ~/quicklisp"))
      (load setup)))
  (when (find-package :ql)
    (funcall (find-symbol "QUICKLOAD" :ql) :sqlite))
  (unless (find-package :com.inuoe.jzon)
    (funcall (find-symbol "QUICKLOAD" :ql) :com.inuoe.jzon)))

(defpackage :eventbus
  (:use :cl)
  (:export #:ensure-schema #:publish #:since #:*db-path* #:max-id)
  (:import-from :com.inuoe.jzon #:parse #:stringify))
(in-package :eventbus)

(defvar *db-path* (merge-pathnames "events.db" (uiop:getcwd))
  "Bus location: the working directory of the process, not the source tree.")

(defun db ()
  (let ((c (sqlite:connect *db-path*)))
    (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
    (sqlite:execute-to-list c "PRAGMA journal_mode=WAL")
    c))

(defun ensure-schema ()
  (let ((c (db)))
    (sqlite:execute-non-query c "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, ts TEXT DEFAULT (datetime('now')), topic TEXT NOT NULL, payload TEXT)")
    (sqlite:execute-non-query c "CREATE INDEX IF NOT EXISTS i ON events(topic, id)")
    (sqlite:disconnect c)))

(defun publish (topic payload)
  (let ((c (db)))
    (sqlite:execute-non-query c "INSERT INTO events(topic,payload) VALUES (?,?)" topic (stringify payload))
    (let ((id (sqlite:last-insert-rowid c)))
      (sqlite:disconnect c) id)))

(defun max-id (&optional topic-glob)
  "Highest event id, optionally within TOPIC-GLOB -- tail cursor for consumers."
  (let ((c (db)))
    (unwind-protect
         (let ((stmt (if topic-glob
                         (sqlite:prepare-statement c "SELECT COALESCE(MAX(id),0) FROM events WHERE topic GLOB ?")
                         (sqlite:prepare-statement c "SELECT COALESCE(MAX(id),0) FROM events"))))
           (when topic-glob (sqlite:bind-parameter stmt 1 topic-glob))
           (sqlite:step-statement stmt)
           (let ((v (sqlite:statement-column-value stmt 0)))
             (sqlite:finalize-statement stmt)
             (or v 0)))
      (sqlite:disconnect c))))

(defun since (last-id &optional topic-glob)
  (let ((c (db)))
    (unwind-protect
         (let ((stmt (if topic-glob
                         (sqlite:prepare-statement c "SELECT id,ts,topic,payload FROM events WHERE id>? AND topic GLOB ? ORDER BY id LIMIT 500")
                         (sqlite:prepare-statement c "SELECT id,ts,topic,payload FROM events WHERE id>? ORDER BY id LIMIT 500"))))
           (sqlite:bind-parameter stmt 1 last-id)
           (when topic-glob (sqlite:bind-parameter stmt 2 topic-glob))
           (let ((acc))
             (loop while (sqlite:step-statement stmt)
                   do (push (list :id (sqlite:statement-column-value stmt 0)
                                  :ts (sqlite:statement-column-value stmt 1)
                                  :topic (sqlite:statement-column-value stmt 2)
                                  :data (parse (or (sqlite:statement-column-value stmt 3) "null")))
                            acc))
             (nreverse acc)))
      (sqlite:disconnect c))))
