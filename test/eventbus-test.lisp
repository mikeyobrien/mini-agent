;;;; eventbus-test.lisp — bus regression: glob, cursor, payloads, tail.
;;;;   cd $(mktemp -d) && timeout 60 sbcl --script <repo>/test/eventbus-test.lisp
;;;; Run from a scratch cwd: the bus lives in ./events.db.
(load (merge-pathnames "../src/eventbus.lisp" *load-truename*))
(in-package :eventbus)

(defvar *fails* 0)
(defmacro check (name form)
  `(if ,form
       (format t "PASS ~a~%" ,name)
       (progn (incf *fails*) (format t "FAIL ~a~%" ,name))))

(defun wait-for (secs pred)
  (loop repeat (* secs 20) until (funcall pred) do (sleep 0.05))
  (funcall pred))

(ensure-schema)
(let* ((a (publish "agents/mia" (dict "n" 0)))
       (b (publish "agents/rex" (dict "n" 0)))
       (c (publish "agents/mia" (dict "n" 1))))
  (check "since filters by glob"
         (equal (mapcar (lambda (e) (getf e :id)) (since (1- a) "agents/rex")) (list b)))
  (check "since is exclusive of the cursor, oldest first"
         (equal (mapcar (lambda (e) (getf e :id)) (since a)) (list b c)))
  (check "payload round-trips as a JSON object"
         (eql 1 (jget (getf (get-event c) :data) "n")))
  (check "get-event of a missing id is nil" (null (get-event (+ c 1000))))
  (check "max-id per glob" (= (max-id "agents/rex") b)))

(check "dict omits nil values"
       (string= (com.inuoe.jzon:stringify (dict "a" 1 "b" nil)) "{\"a\":1}"))
(check "jget walks nested objects"
       (eql 7 (jget (com.inuoe.jzon:parse "{\"x\":{\"y\":7}}") "x" "y")))

;; tail: wakes on an in-image publish long before its idle poll, and one
;; failing event does not stop the ones after it.
(let ((seen nil) (lock (sb-thread:make-mutex)))
  (sb-thread:make-thread
   (lambda ()
     (let ((*error-output* (make-broadcast-stream)))
       (tail "t/*" (lambda (e)
                     (let ((n (jget (getf e :data) "n")))
                       (when (eql n 0) (error "poison"))
                       (sb-thread:with-mutex (lock) (push n seen))))
             :idle 30)))
   :name "tail-under-test")
  (sleep 0.5)                           ; tail parked on its 30s wait
  (publish "t/x" (dict "n" 0))
  (publish "t/x" (dict "n" 1))
  (publish "other" (dict "n" 2))
  (check "tail delivers within 2s despite a 30s idle poll"
         (wait-for 2 (lambda () (sb-thread:with-mutex (lock) (member 1 seen)))))
  (check "tail skips a failing event and only sees its glob"
         (equal (sb-thread:with-mutex (lock) seen) '(1))))

(format t "eventbus-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
