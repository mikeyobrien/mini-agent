;;;; agent-test.lisp — agent loop units; the LM is stubbed, nothing networked.
;;;;   timeout 60 sbcl --script test/agent-test.lisp   ; exit 0 = pass
(require :uiop)
(require :sb-posix)
(sb-posix:unsetenv "MINI_AGENT_AUTORUN")   ; else loading runs main and quits 0
(load (merge-pathnames "../src/agent.lisp" *load-truename*))
(in-package :mini-agent)

(defvar *fails* 0)
(defmacro check (name form)
  `(if ,form
       (format t "PASS ~a~%" ,name)
       (progn (incf *fails*) (format t "FAIL ~a~%" ,name))))

;; execute: the model's observation is the command output minus trailing
;; newlines - letters at either end are content.
(check "output ending in n kept" (string= (execute "printf 'fun'") "fun"))
(check "trailing newlines dropped" (string= (execute "printf 'a\\n\\n'") "a"))
(check "leading n kept" (string= (execute "printf 'nap'") "nap"))
(check "stderr merged" (string= (execute "echo oops >&2") "oops"))

;;; run, with the LM stubbed at its boundary (query-lm). The stub builds the
;;; real request so the test sees exactly what would go on the wire.
(defun load-eventbus () nil)            ; keep test runs off any live bus
(defvar *requests* nil)
(defvar *replies* nil "Assistant messages the stub LM returns, in order.")
(defun query-lm (history)
  (push (parse (build-request history)) *requests*)
  (parse (or (pop *replies*)
             "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"true\\\"}\"}}]}")))

(defun run-quietly (task)
  (let ((*standard-output* (make-broadcast-stream)))
    (run task)))

(setf *requests* nil
      *replies* (list "{\"role\":\"assistant\",\"content\":\"the end\"}"))
(multiple-value-bind (answer ok) (run-quietly "anything")
  (check "run returns the model's answer" (and ok (equal answer "the end")))
  (let ((sys (gethash "content" (elt (gethash "messages" (first *requests*)) 0))))
    ;; skills/rex ships in the repo: a real run must advertise it
    (check "a real run's system prompt lists the repo's skills"
           (search "**rex**" sys))))

(setf *requests* nil *replies* nil)
(let ((*max-steps* 3))
  (multiple-value-bind (reason ok) (run-quietly "loop forever")
    (check "step budget stops a model that never answers" (= 3 (length *requests*)))
    (check "budget exhaustion is reported as a failure" (and (not ok) (search "budget" reason)))))

(format t "agent-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
