;;;; dispatch-test.lisp — delivery retirement regression. No network.
;;;;   cd $(mktemp -d) && timeout -k 5 60 sbcl --script <repo>/test/dispatch-test.lisp
;;;; Run from a scratch cwd: eventd opens events.db / deliveries.db there.
(require :uiop)
;; Definitions only, and no channels.d/: a test that loaded the real Telegram
;; connector and reached MAIN once long-polled the live bot for an hour.
(setf (uiop:getenv "EVENTD_NO_MAIN") "1"
      (uiop:getenv "CHANREG_DIR") "/nonexistent/")
(load (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname)) :if-does-not-exist nil)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)) :if-does-not-exist nil)
(load (merge-pathnames "../src/eventd.lisp" *load-truename*))
(in-package :eventd)

(defvar *fails* 0)
(defmacro check (name form)
  `(if ,form
       (format t "PASS ~a~%" ,name)
       (progn (incf *fails*) (format t "FAIL ~a~%" ,name))))

(defun status-of (name event-id)
  (with-ddb (c)
    (sqlite:execute-single c "SELECT status FROM deliveries WHERE channel=? AND event_id=?"
                           name event-id)))

(uiop:with-temporary-file (:pathname tmp)
  (let ((*dispatch-db* (format nil "~a.db" (namestring tmp)))
        (*error-output* (make-broadcast-stream)))
    (ensure-deliveries-schema)
    ;; event 3 delivered, event 7 (the newest) keeps failing
    (claim "t" 3) (mark-sent "t" 3)
    (let ((attempts (claim "t" 7)))
      (requeue "t" 7 attempts))
    (check "failing event below the limit is pending" (equal (status-of "t" 7) "pending"))
    (check "pending event is due for retry" (member 7 (due-claims "t" (+ (get-universal-time) 10000))))

    (loop repeat (1- *max-attempts*) do (requeue "t" 7 (claim "t" 7)))
    (check "event retired at the limit is dead, not sent" (equal (status-of "t" 7) "dead"))
    (check "dead event is never retried"
           (not (member 7 (due-claims "t" (+ (get-universal-time) 10000)))))
    (check "dead tail event holds the cursor (no re-claim from 3)"
           (= (channel-cursor "t") 7))
    (check "other channels unaffected" (= (channel-cursor "other") 0))
    ;; Full tick against a down channel: a failed newest event must wait out
    ;; its backoff (>= 4s after attempt 1), not be re-sent as "fresh" next tick.
    (let ((tries 0))
      (chanreg:register "down" "harness/down" (lambda (&rest _) (declare (ignore _))
                                                 (incf tries) (error "channel down")))
      (let ((id (eventbus:publish "harness/down" (make-hash-table))))
        (dispatch-channel (chanreg:find-channel "down"))
        (dispatch-channel (chanreg:find-channel "down"))
        (dispatch-channel (chanreg:find-channel "down"))
        (check "backoff honored for a failed tail event (1 send in 3 immediate ticks)"
               (= tries 1))
        (check "failed tail event is pending, awaiting its retry"
               (equal (status-of "down" id) "pending"))))
    (uiop:delete-file-if-exists *dispatch-db*)))

(format t "dispatch-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
