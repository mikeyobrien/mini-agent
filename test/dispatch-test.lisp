;;;; dispatch-test.lisp — delivery retirement regression. No network.
;;;;   cd $(mktemp -d) && EVENTD_NO_MAIN=1 timeout 60 sbcl --script <repo>/test/dispatch-test.lisp
;;;; Run from a scratch cwd: eventd opens events.db / deliveries.db there.
(require :uiop)
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
    (uiop:delete-file-if-exists *dispatch-db*)))

(format t "dispatch-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
