;;;; eventbus.lisp — the event bus, in the same language as everything else.
;;;; Schema contract: events(id, ts, topic, payload-json). Any sqlite client speaks it.

(eval-when (:load-toplevel :execute)
  (unless (find-package :sqlite)
    (let ((setup (or (probe-file (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname)))
                     (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))))
      (unless setup (error "need quicklisp at ~~/.quicklisp or ~~/quicklisp"))
      (load setup)))
  (when (find-package :ql)
    (funcall (find-symbol "QUICKLOAD" :ql) :sqlite))
  (unless (find-package :com.inuoe.jzon)
    (funcall (find-symbol "QUICKLOAD" :ql) :com.inuoe.jzon)))

(defpackage :eventbus
  (:use :cl)
  (:export #:ensure-schema #:publish #:since #:get-event #:*db-path* #:max-id
           #:publish-count #:await-publish #:tail #:dict #:jget)
  (:import-from :com.inuoe.jzon #:parse #:stringify))
(in-package :eventbus)

(defvar *db-path* (merge-pathnames "events.db" (uiop:getcwd))
  "Bus location: the working directory of the process, not the source tree.")

;;; --- payload helpers ---------------------------------------------------------

(defun dict (&rest kvs)
  "(dict \"k\" v ...) -> equal hash-table, the JSON-object payload shape.
NIL values are omitted: optional fields are absent, never null."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          when v do (setf (gethash k h) v))
    h))

(defun jget (h &rest keys)
  "Walk KEYS into nested JSON objects; NIL at the first missing step."
  (dolist (k keys h)
    (setf h (and (hash-table-p h) (gethash k h)))))

;;; --- storage ---------------------------------------------------------------------

(defun db ()
  (let ((c (sqlite:connect *db-path*)))
    (sqlite:execute-to-list c "PRAGMA busy_timeout=5000")
    (sqlite:execute-to-list c "PRAGMA journal_mode=WAL")
    c))

(defmacro with-db ((conn) &body body)
  `(let ((,conn (db)))
     (unwind-protect (progn ,@body) (sqlite:disconnect ,conn))))

(defun ensure-schema ()
  (with-db (c)
    (sqlite:execute-non-query c "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, ts TEXT DEFAULT (datetime('now')), topic TEXT NOT NULL, payload TEXT)")
    (sqlite:execute-non-query c "CREATE INDEX IF NOT EXISTS i ON events(topic, id)")))

;;; In-image wakeups: a consumer in this process blocks until the next publish
;;; instead of polling. Writers in other processes are seen at the wait timeout.
(defvar *pub-lock* (sb-thread:make-mutex :name "eventbus-publish"))
(defvar *pub-cv* (sb-thread:make-waitqueue :name "eventbus-publish"))
(defvar *pub-count* 0)

(defun publish-count () *pub-count*)

(defun await-publish (seen timeout)
  "Return once a publish in this image moves the count past SEEN (a prior
PUBLISH-COUNT), or after TIMEOUT seconds."
  (sb-thread:with-mutex (*pub-lock*)
    (when (= seen *pub-count*)
      (sb-thread:condition-wait *pub-cv* *pub-lock* :timeout timeout))))

(defun publish (topic payload)
  (prog1 (with-db (c)
           (sqlite:execute-non-query c "INSERT INTO events(topic,payload) VALUES (?,?)" topic (stringify payload))
           (sqlite:last-insert-rowid c))
    (sb-thread:with-mutex (*pub-lock*)
      (incf *pub-count*)
      (sb-thread:condition-broadcast *pub-cv*))))

(defun max-id (&optional topic-glob)
  "Highest event id, optionally within TOPIC-GLOB -- tail cursor for consumers."
  (with-db (c)
    (or (if topic-glob
            (sqlite:execute-single c "SELECT MAX(id) FROM events WHERE topic GLOB ?" topic-glob)
            (sqlite:execute-single c "SELECT MAX(id) FROM events"))
        0)))

(defun rows->events (rows)
  (mapcar (lambda (r)
            (destructuring-bind (id ts topic payload) r
              (list :id id :ts ts :topic topic :data (parse (or payload "null")))))
          rows))

(defparameter *batch* 500 "Max events per SINCE call.")

(defun since (last-id &optional topic-glob)
  "Events with id > LAST-ID (matching TOPIC-GLOB), oldest first, at most *BATCH*."
  (with-db (c)
    (rows->events
     (if topic-glob
         (sqlite:execute-to-list c "SELECT id,ts,topic,payload FROM events WHERE id>? AND topic GLOB ? ORDER BY id LIMIT ?" last-id topic-glob *batch*)
         (sqlite:execute-to-list c "SELECT id,ts,topic,payload FROM events WHERE id>? ORDER BY id LIMIT ?" last-id *batch*)))))

(defun get-event (id)
  "The event with ID, or NIL."
  (with-db (c)
    (first (rows->events
            (sqlite:execute-to-list c "SELECT id,ts,topic,payload FROM events WHERE id=?" id)))))

;;; --- consuming -------------------------------------------------------------------

(defun tail (topic-glob handler &key (from (max-id topic-glob)) (idle 2) (name "tail"))
  "Call HANDLER on each event matching TOPIC-GLOB with id > FROM, oldest first,
forever. FROM defaults to the current tail: only events published from now on.
A handler error is logged and that event skipped -- one poison event must not
wedge the consumer. Wakes on publishes in this image; polls every IDLE seconds
for other writers. Never returns."
  (let ((cursor from))
    (loop
      (let ((seen (publish-count))
            (batch nil))
        (handler-case
            (progn
              (setf batch (since cursor topic-glob))
              (dolist (e batch)
                (setf cursor (getf e :id))
                (handler-case (funcall handler e)
                  (error (err)
                    (format *error-output* "~a: event ~a: ~a~%" name (getf e :id) err)))))
          (error (err)
            (format *error-output* "~a: ~a~%" name err)
            (sleep idle)))
        (when (< (length batch) *batch*)
          (await-publish seen idle))))))
