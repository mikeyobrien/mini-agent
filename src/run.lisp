;;;; Entry point:
;;;;   MINI_AGENT_BASE_URL=... MINI_AGENT_MODEL=... sbcl --script run.lisp "task..."
(require :uiop)
(let ((args (uiop:command-line-arguments)))
  (when args
    (setf (uiop:getenv "MINI_AGENT_AUTORUN") "1")))
(setf (uiop:getenv "MINI_AGENT_AUTORUN") "1")
(load (merge-pathnames "agent.lisp" *load-truename*))
