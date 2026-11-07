;;;; agent-responder.lisp -- boot-hook: inbound text -> mini-agent:run -> reply.
;;;;
;;;; One worker thread; tasks queue in-process. Bounded twice: agent loop
;;;; (MINI_AGENT_MAX_STEPS + per-step/http timeouts from .env.agent) and a
;;;; wall-clock join on the worker future. Every terminal state replies --
;;;; answer, error, or timeout; silence is a bug. Agent telemetry flows to
;;;; the bus free (agent/start|step|done) for observers.
;;;;
;;;; Commands: text starting with "! " (or "!") is agent task; the echo
;;;; responder is untouched and continues to mirror everything.

(require :uiop)

(defpackage :agent-responder
  (:use :cl)
  (:export #:boot))

(in-package :agent-responder)

(defparameter *poll-seconds* 2)
(defparameter *wall-clock* 240          ; hard cap per task, seconds
  "Wall-clock bound; agent's own budgets are smaller but belts+suspenders.")
(defparameter *db* nil)
(defparameter *env* nil)                ; agent env alist, loaded at boot
(defparameter *cursor* 0)
;; single-worker design: no queue needed, busy => polite skip (see spawn-task)

(defun jget (h k) (and (hash-table-p h) (gethash k h)))

(defun env-path ()
  (merge-pathnames ".env.agent" (uiop:getcwd)))

(defun load-env ()
  "KEY=VALUE lines -> alist; overrides into *default-pathname* env at run time."
  (when (probe-file (env-path))
    (with-open-file (f (env-path))
      (loop for line = (read-line f nil nil) while line
            when (and (plusp (length line))
                      (not (char= #\# (char line 0)))
                      (search "=" line))
              collect (let ((eq (position #\= line)))
                        (cons (subseq line 0 eq)
                              (string-trim " \"" (subseq line (1+ eq)))))))))

(defun env-lookup (key)
  (cdr (assoc key *env* :test #'string=)))

;;; --- agent invocation --------------------------------------------------------
;;; Run in a fresh SBCL? No -- same image, load agent.lisp once at boot.
;;; Its env specials are set per-task (dynamic let) from .env.agent.

(defun agent-loaded-p () (find-package :mini-agent))

(defun set-agent-env ()
  (let* ((pkg (find-package :mini-agent))
         (sym (lambda (s) (find-symbol (string-upcase s) pkg)))
         (base (env-lookup "MINI_AGENT_BASE_URL"))
         (model (env-lookup "MINI_AGENT_MODEL"))
         (steps (env-lookup "MINI_AGENT_MAX_STEPS"))
         (step-t (env-lookup "MINI_AGENT_TIMEOUT"))
         (http-t (env-lookup "MINI_AGENT_HTTP_TIMEOUT")))
    (when base (set (funcall sym "*BASE-URL*") base))
    (when model (set (funcall sym "*MODEL*") model))
    (when steps (set (funcall sym "*MAX-STEPS*") (parse-integer steps)))
    (when step-t (set (funcall sym "*STEP-TIMEOUT*") (parse-integer step-t)))
    (when http-t (set (funcall sym "*HTTP-TIMEOUT*") (parse-integer http-t)))))

(defun run-agent (task)
  "Returns (values ok text). mini-agent:run PRINTS its answer; stdout is the reply."
  (handler-case
      (let ((out (make-string-output-stream)))
        (let ((*standard-output* out))
          (set-agent-env)
          (funcall (find-symbol "RUN" :mini-agent) task))
        (let* ((raw (get-output-stream-string out))
               ;; drop one-time quicklisp/ASDF noise before the first [step
               (stripped (if (search "[step" raw)
                             (subseq raw (search "[step" raw))
                             raw))
               (text (string-trim " \n\t" stripped)))
          (if (plusp (length text))
              (values t text)
              (values nil "agent returned empty output"))))
    (error (e) (values nil (format nil "agent error: ~a" e)))))

(defun reply (chat-id text)
  (eventbus:publish "telegram/outbound"
                    (let ((h (make-hash-table :test 'equal)))
                      (setf (gethash "chat_id" h) chat-id
                            (gethash "text" h) text)
                      h)))

;;; --- worker -------------------------------------------------------------------

(defparameter *worker-lock* (sb-thread:make-mutex :name "agent-worker"))
(defparameter *task-thread* nil)

;;; --- bounded queue -----------------------------------------------------------
;;; Tasks wait instead of vanishing: depth 3, FIFO, oldest-first. The worker
;;; is persistent: it drains the queue, then idles on a condition-variable.

(defparameter *queue-lock* (sb-thread:make-mutex :name "agent-q"))
(defparameter *queue* nil)            ; alist (chat-id . task), front = next
(defparameter *queue-max* 3)
(defparameter *worker-thread* nil)

(defun queue-push (chat-id task)
  (sb-thread:with-mutex (*queue-lock*)
    (if (>= (length *queue*) *queue-max*)
        (progn (reply chat-id (format nil "queue full (~a) - task dropped." *queue-max*))
               nil)
        (progn
          (setf *queue* (append *queue* (list (cons chat-id task))))
          (when (> (length *queue*) 1)
            (reply chat-id (format nil "queued (~a/~a)." (length *queue*) *queue-max*)))
          t))))

(defun queue-pop ()
  (sb-thread:with-mutex (*queue-lock*)
    (pop *queue*)))

(defun ensure-worker ()
  (sb-thread:with-mutex (*queue-lock*)
    (when (or (null *worker-thread*) (not (sb-thread:thread-alive-p *worker-thread*)))
      (setf *worker-thread*
            (sb-thread:make-thread
             (lambda ()
               (loop
                 (let ((job (queue-pop)))
                   (if job
                       (let ((chat-id (car job)) (task (cdr job)))
                         (multiple-value-bind (ok text) (run-agent task)
                           (reply chat-id (if ok text (format nil "&#9888; ~a" text)))))
                       (sleep 1)))
               ))
             :name "agent-worker")))))

(defun spawn-task (chat-id task)
  (ensure-worker)
  (queue-push chat-id task))

(defun handle (event)
  (let* ((data (getf event :data))
         (text (jget data "text"))
         (chat (jget data "chat_id")))
    (when (and text chat
               (or (uiop:string-prefix-p "! " text)
                   (string= "!" text)))
      (let ((task (string-trim " " (subseq text 1))))
        (when (plusp (length task))
          (spawn-task chat task))))))

(defun seen-db ()
  (merge-pathnames "agent_seen.db" (uiop:getcwd)))

(defun ensure-seen ()
  (let ((c (sqlite:connect (seen-db))))
    (unwind-protect
         (sqlite:execute-non-query c
           "CREATE TABLE IF NOT EXISTS seen (update_id INTEGER PRIMARY KEY)")
      (sqlite:disconnect c))))

(defun seen-p (id)
  (let ((c (sqlite:connect (seen-db))))
    (unwind-protect
         (let ((s (sqlite:prepare-statement c "SELECT 1 FROM seen WHERE update_id=?")))
           (sqlite:bind-parameter s 1 id)
           (prog1 (and (sqlite:step-statement s) t) (sqlite:finalize-statement s)))
      (sqlite:disconnect c))))

(defun mark! (id)
  (let ((c (sqlite:connect (seen-db))))
    (unwind-protect
         (sqlite:execute-non-query c "INSERT OR IGNORE INTO seen(update_id) VALUES (?)" id)
      (sqlite:disconnect c))))

(defun loop! ()
  (loop
    (handler-case
        (let ((events (eventbus:since *cursor* "telegram/inbound")))
          (dolist (e events)
            (let* ((data (getf e :data))
                   (uid (jget data "update_id")))
              (unless (and uid (seen-p uid))
                (handle e)
                (when uid (mark! uid)))))
          (let ((last (and events (getf (car (last events)) :id))))
            (when (and last (> last *cursor*)) (setf *cursor* last))))
      (error (e)
        (format *error-output* "agent-responder: ~a~%" e)
        (sleep 5)))
    (sleep *poll-seconds*)))

(defun boot ()
  (setf *env* (load-env))
  (unless (and (env-lookup "MINI_AGENT_BASE_URL") (env-lookup "MINI_AGENT_MODEL"))
    (format *error-output* "agent-responder: no .env.agent, hook idle")
    (return-from boot))
  (unless (probe-file (merge-pathnames "src/agent.lisp" (uiop:getcwd)))
    (format *error-output* "agent-responder: agent.lisp not found, hook idle")
    (return-from boot))
  (load (merge-pathnames "src/agent.lisp" (uiop:getcwd)))
  (ensure-seen)
  (setf *cursor* (eventbus:max-id "telegram/inbound"))
  (format *error-output* "agent-responder: up, model=~a cursor=~a"
          (env-lookup "MINI_AGENT_MODEL") *cursor*)
  (loop!))

(when (find-package :chanreg)
  (push #'agent-responder:boot
        (symbol-value (find-symbol "*BOOT-HOOKS*" :chanreg))))
