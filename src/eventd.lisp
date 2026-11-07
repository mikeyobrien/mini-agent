;;;; eventd.lisp — always-on event bus daemon.
;;;; Long-running SBCL image: loads eventbus, keeps a WAL db open, exposes
;;;;  - channel fan-out: anything published to chan/<name> is appended to
;;;;    per-channel subscriber views (chan-<name>.db) for pollers/forwarders
;;;;  - stdin REPL: "topic json" per line to publish; "since <id> [glob]" dumps
;;;; Run:  sbcl --load eventd.lisp   (foreground)
;;;;       nohup sbcl --load eventd.lisp &  (background; pid in eventd.pid)

(load (merge-pathnames "eventbus.lisp" *load-truename*))
(eventbus:ensure-schema)

(defpackage :eventd (:use :cl) (:import-from :eventbus #:publish #:since))
(in-package :eventd)

(defparameter *pid-file* (merge-pathnames "eventd.pid" (uiop:getcwd)))
(defparameter *log* *standard-output*)

;;; Heartbeat is a liveness tick, not an event. The 30s cadence proves the
;;; process is alive for monitors; real events flow the instant they happen
;;; (every publish writes straight through). Interval is env-tunable.
(defparameter *beat-interval*
  (parse-integer (or (uiop:getenv "EVENTD_BEAT_SECONDS") "30")))

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
  (format t "eventd up; pid in ~a; stdin: \"topic {json}\" | since <id> [glob]~%" *pid-file*)
  (let ((hb (sb-thread:make-thread #'heartbeat :name "heartbeat")))
    (repl)
    ;; stdin exhausted (daemon/redirect mode): keep serving beats + bus forever
    (sb-thread:join-thread hb)))

(defun stop ()
  (let ((pid (with-open-file (f *pid-file* :direction :input) (parse-integer (read-line f)))))
    (sb-posix:kill pid 15)))


(main)
