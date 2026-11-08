;;;; agent-test.lisp — agent loop units that need no LM.
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

(format t "agent-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
