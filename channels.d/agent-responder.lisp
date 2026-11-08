;;;; agent-responder.lisp -- boot hook: telegram/inbound text -> mini-agent:run -> reply.
;;;;
;;;; One worker drains a FIFO of depth 3. Every accepted task is acked, typing
;;;; shows while it runs, and every terminal state replies -- answer or error;
;;;; silence is a bug. Runs are bounded by MINI_AGENT_MAX_STEPS and the
;;;; per-step/LM timeouts in .env.agent. agent/* telemetry carries the task's
;;;; chat_id (mini-agent:*context*), which is how observers such as
;;;; progress-notifier find the chat. "echo ..." belongs to echo-responder.

(require :uiop)

;;; mini-agent reads its knobs from the environment when it loads: put
;;; .env.agent (cwd) there first. AUTORUN would run main and quit the daemon.
(let ((path (merge-pathnames ".env.agent" (uiop:getcwd))))
  (when (probe-file path)
    (dolist (line (uiop:read-file-lines path))
      (let ((eq (position #\= line)))
        (when (and eq (plusp eq) (char/= #\# (char line 0)))
          (sb-posix:setenv (subseq line 0 eq)
                           (string-trim " \"" (subseq line (1+ eq))) 1))))))
(sb-posix:unsetenv "MINI_AGENT_AUTORUN")
(load (merge-pathnames "src/agent.lisp" (chanreg:repo-root)))

(defpackage :agent-responder
  (:use :cl)
  (:import-from :eventbus #:dict #:jget)
  (:export #:boot))

(in-package :agent-responder)

(defparameter +ws+ '(#\Space #\Tab #\Newline #\Return)
  "Whitespace for STRING-TRIM. A literal \" \\n\" is space + the letter n.")
(defparameter *queue-max* 3)
(defparameter *typing-every* 4 "Seconds between typing actions; each shows ~5s.")

(defun reply (chat-id text &optional reply-to)
  (eventbus:publish "telegram/outbound"
                    (dict "chat_id" chat-id "text" text "reply_to" reply-to)))

(defun preview (task) (subseq task 0 (min 60 (length task))))

;;; --- per-chat memory -----------------------------------------------------------
;;; state/<chat>.md in the daemon's cwd: a plain file the agent edits with
;;; shell tools. The prompt carries its tail.

(defun state-path (chat-id)
  (merge-pathnames (format nil "state/~a.md" chat-id) (uiop:getcwd)))

(defun memory-tail (chat-id &optional (lines 30))
  (let ((path (state-path chat-id)))
    (when (probe-file path)
      (let ((all (uiop:read-file-lines path)))
        (string-trim +ws+ (format nil "~{~a~%~}" (last all lines)))))))

(defun prompt (chat-id task)
  (ensure-directories-exist (state-path chat-id))
  (let ((mem (memory-tail chat-id)))
    (format nil "~a~%Task: ~a~%Work in ~a."
            (if (plusp (length mem))
                (format nil "Your persistent memory: state/~a.md (tail below). Edit it freely with any
shell tool - append, rewrite, prune, restructure. Keep it terse and useful;
it is your only memory between runs.
--- memory tail ---
~a
--- end ---" chat-id mem)
                (format nil "You have no memory file yet. Create state/~a.md and keep durable facts
there - edit it freely with any shell tool. It is your only memory." chat-id))
            task (namestring (uiop:getcwd)))))

;;; --- queue + worker ------------------------------------------------------------

(defvar *lock* (sb-thread:make-mutex :name "agent-queue"))
(defvar *wake* (sb-thread:make-waitqueue :name "agent-queue"))
(defvar *queue* nil "Waiting jobs (chat-id reply-to task), front = next.")
(defvar *busy* nil "T while the worker runs a job: a new task queues behind it.")

(defun enqueue (chat-id task reply-to)
  "Queue TASK and ack it, or say the queue is full. The ack is published under
the lock, so it always precedes the worker's answer."
  (sb-thread:with-mutex (*lock*)
    (cond
      ((>= (length *queue*) *queue-max*)
       (reply chat-id (format nil "queue full (~a) - task dropped." *queue-max*)))
      (t
       (reply chat-id (if (or *queue* *busy*)
                          (format nil "queued (~a/~a): ~a"
                                  (1+ (length *queue*)) *queue-max* (preview task))
                          (format nil "working: ~a" (preview task))))
       (setf *queue* (append *queue* (list (list chat-id reply-to task))))
       (sb-thread:condition-notify *wake*)))))

(defun next-job ()
  "Block until a job is queued; mark the worker busy and return it."
  (sb-thread:with-mutex (*lock*)
    (setf *busy* nil)
    (loop until *queue* do (sb-thread:condition-wait *wake* *lock*))
    (setf *busy* t)
    (pop *queue*)))

(defun call-with-typing (chat-id fn)
  "FN's values, with a typing indicator in CHAT-ID while it runs. The
heartbeat is joined before returning: no typing after the answer."
  (let* ((done nil)
         (beat (sb-thread:make-thread
                (lambda ()
                  (loop with next = 0
                        until done
                        do (when (>= (get-universal-time) next)
                             (ignore-errors
                               (eventbus:publish "telegram/typing" (dict "chat_id" chat-id)))
                             (setf next (+ (get-universal-time) *typing-every*)))
                           (sleep 0.2)))
                :name "typing-heartbeat")))
    (unwind-protect (funcall fn)
      (setf done t)
      (sb-thread:join-thread beat :default nil))))

(defun run-task (chat-id task)
  "(values ok text): the agent's answer, or why there is none."
  (handler-case
      (let ((*standard-output* (make-broadcast-stream)) ; CLI trace; answer is the value
            (mini-agent:*context* (list "chat_id" chat-id)))
        (multiple-value-bind (answer ok) (mini-agent:run (prompt chat-id task))
          (let ((text (string-trim +ws+ (or answer ""))))
            (cond ((not ok) (values nil text))
                  ((string= text "") (values nil "agent returned an empty answer"))
                  (t (values t text))))))
    (error (e) (values nil (format nil "agent error: ~a" e)))))

(defun work ()
  (loop
    (destructuring-bind (chat-id reply-to task) (next-job)
      (handler-case
          (multiple-value-bind (ok text)
              (call-with-typing chat-id (lambda () (run-task chat-id task)))
            (reply chat-id (if ok text (format nil "⚠ ~a" text)) reply-to))
        (error (e)
          (format *error-output* "agent-worker: ~a~%" e))))))

;;; --- inbound -------------------------------------------------------------------

(defun handle (event)
  "Plain text (or \"! task\") becomes a task; \"echo ...\" is left alone."
  (let* ((data (getf event :data))
         (text (string-trim +ws+ (or (jget data "text") "")))
         (chat-id (jget data "chat_id"))
         ;; reply_to only for real Telegram messages (update_id present);
         ;; synthetic probes carry fabricated ids that 400 the send.
         (reply-to (and (jget data "update_id") (jget data "message_id"))))
    (when (uiop:string-prefix-p "!" text)
      (setf text (string-trim +ws+ (subseq text 1))))
    (unless (or (null chat-id) (string= text "") (uiop:string-prefix-p "echo " text))
      (enqueue chat-id text reply-to))))

(defun boot ()
  (unless (and mini-agent:*base-url* mini-agent:*model*)
    (format *error-output* "agent-responder: no MINI_AGENT_BASE_URL/MODEL (.env.agent), idle~%")
    (return-from boot))
  (sb-thread:make-thread #'work :name "agent-worker")
  (format *error-output* "agent-responder: up, model=~a~%" mini-agent:*model*)
  (eventbus:tail "telegram/inbound" #'handle :name "agent-responder"))

(chanreg:add-boot-hook "agent-responder" #'boot)
