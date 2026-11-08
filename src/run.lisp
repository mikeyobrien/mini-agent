;;;; Entry point:
;;;;   MINI_AGENT_BASE_URL=... MINI_AGENT_MODEL=... sbcl --script run.lisp "task..."
;;;; AUTORUN makes agent.lisp call main once loaded.
(require :uiop)
(setf (uiop:getenv "MINI_AGENT_AUTORUN") "1")
(load (merge-pathnames "agent.lisp" *load-truename*))
