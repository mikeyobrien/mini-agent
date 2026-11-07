;;;; evbus.lisp — the event bus, in the same language as everything else.
;;;; Same schema, same semantics as the python sketch. Deps: sqlite (quicklisp), com.inuoe.jzon.

(eval-when (:load-toplevel :execute)
  (unless (find-package :sqlite)
    (let ((setup (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname))))
      (unless (probe-file setup) (error "need quicklisp at ~a" setup))
      (load setup)))
  (when (find-package :ql)
    (funcall (find-symbol "QUICKLOAD" :ql) :sqlite))
  (unless (find-package :com.inuoe.jzon)
    (funcall (find-symbol "QUICKLOAD" :ql) :com.inuoe.jzon)))

(defpackage :evbus
  (:use :cl)
  (:export #:ensure-schema #:publish #:since #:*db-path*)
  (:import-from :com.inuoe.jzon #:parse #:stringify))
(in-package :evbus)

(defvar *db-path* (merge-pathnames "events.db" (or *load-truename* *default-pathname-defaults*)))

(defun db ()
  (let ((c (sqlite:connect *db-path*)))
    (sqlite:execute-non-query c "PRAGMA journal_mode=WAL")
    (sqlite:execute-non-query c "PRAGMA busy_timeout=5000")
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
