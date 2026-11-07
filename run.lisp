;;;; Entry point:
;;;;   MINI_AGENT_BASE_URL=... MINI_AGENT_MODEL=... sbcl --script run.lisp "task..."
;;;; Bootstraps quicklisp/com.inuoe.jzon via agent.lisp.
(load (merge-pathnames "agent.lisp" *load-truename*))
