;;;; channels.d/telegram.lisp -- Telegram connector. Self-registering.
;;;; Outbound: telegram/outbound -> sendMessage
;;;;   payload: {"text": "...", "chat_id": N}  (reply_to, thread_id, parse_mode optional)
;;;;   telegram/typing {"chat_id": N} -> sendChatAction typing (~5s)
;;;; Inbound: getUpdates long-poll -> publish "telegram/inbound".
;;;; Token: TELEGRAM_BOT_TOKEN env, or .env.telegram in repo root, cwd or $HOME.
;;;; TELEGRAM_API_BASE overrides https://api.telegram.org (test harness).

(defpackage :chan-telegram
  (:use :cl)
  (:import-from :uiop #:getenv)
  (:import-from :eventbus #:dict #:jget))

(in-package :chan-telegram)

;;; --- config -----------------------------------------------------------------

(defun env-file-token ()
  "TELEGRAM_BOT_TOKEN from .env.telegram: repo root, cwd, or $HOME."
  (dolist (base (list (chanreg:repo-root) (uiop:getcwd) (user-homedir-pathname)))
    (let ((path (merge-pathnames ".env.telegram" base)))
      (when (probe-file path)
        (with-open-file (f path)
          (loop for line = (read-line f nil nil) while line
                when (uiop:string-prefix-p "TELEGRAM_BOT_TOKEN=" line)
                  do (return-from env-file-token
                       (string-trim " \"'" (subseq line 19)))))))))

(defun token ()
  (or (getenv "TELEGRAM_BOT_TOKEN") (env-file-token)
      (error "chan-telegram: no TELEGRAM_BOT_TOKEN (env or .env.telegram)")))

(defun curl-string (s)
  "S as a double-quoted curl config value."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for ch across s
          do (when (member ch '(#\\ #\")) (write-char #\\ o))
             (write-char ch o))
    (write-char #\" o)))

(defun api (method &optional payload)
  "POST to the Bot API. Returns the parsed result or signals.
The URL carries the token, so curl reads it from a stdin config (-K -),
never argv: argv is world-readable through ps."
  (let* ((url (format nil "~a/bot~a/~a"
                      (or (getenv "TELEGRAM_API_BASE") "https://api.telegram.org")
                      (token) method))
         (config (format nil "url = ~a~%~@[header = \"Content-Type: application/json\"~%data-binary = ~a~%~]"
                         (curl-string url)
                         (and payload (curl-string (com.inuoe.jzon:stringify payload)))))
         (out (uiop:run-program '("curl" "-s" "--max-time" "30" "-K" "-")
                                :input (make-string-input-stream config)
                                :output :string :external-format :utf-8
                                :ignore-error-status t))
         (resp (ignore-errors (com.inuoe.jzon:parse out))))
    (unless (and (hash-table-p resp) (gethash "ok" resp))
      (error "telegram api ~a failed: ~a" method out))
    (gethash "result" resp)))


;;; --- chunking (P1 #5) ---------------------------------------------------------

(defparameter +tg-chunk+ 4088
  "Per-message budget; headroom below the 4096 API limit for suffixes.")

(defun para-cut (text from to)
  "Largest c in [from+2,to] with a blank line ending at c, else nil."
  (loop for c from to downto (+ 2 from)
        when (and (char= #\Newline (char text (1- c)))
                  (char= #\Newline (char text (- c 2))))
          return c))

(defun chunk-text (text &optional (limit +tg-chunk+))
  (if (or (null text) (<= (length text) limit))
      (list text)
      (let ((out nil) (pos 0) (n (length text)))
        (loop while (< pos n)
              for hard = (min n (+ pos limit))
              for end = (or (and (< hard n) (para-cut text pos hard)) hard)
              do (push (subseq text pos end) out)
                 (setf pos end))
        (nreverse out))))

(defun copy-hash-table (h)
  (let ((n (make-hash-table :test 'equal)))
    (when (hash-table-p h)
      (maphash (lambda (k v) (setf (gethash k n) v)) h))
    n))

;;; --- outbound ----------------------------------------------------------------

(defun send-payload (method payload)
  "As given first; on failure one retry with parse_mode and reply_to dropped
(a bad entity or reply_to poisons the send). A second failure raises, so the
dispatcher's backoff takes over."
  (handler-case (api method payload)
    (error (e)
      (let ((h (copy-hash-table payload)))
        (remhash "parse_mode" h)
        (remhash "reply_to_message_id" h)
        (format *error-output* "chan-telegram fallback: ~a~%" e)
        (api method h)))))

(defun outbound-dispatch (id ts topic data)
  "telegram/* -> Bot API. T handled; nil/raise => delivery retry."
  (declare (ignore id ts))
  (cond
    ((equal topic "telegram/outbound")
     (let ((text (jget data "text"))
           (chat (jget data "chat_id")))
       (unless (and text chat)
         (error "telegram/outbound needs text+chat_id"))
       (let* ((chunks (chunk-text text))
              (n (length chunks))
              ;; Markdown opt-in via payload; plain text by default - agent
              ;; output with unbalanced _/* broke entities and poisoned retries.
              (base (dict "chat_id" chat
                          "parse_mode" (jget data "parse_mode")
                          "message_thread_id" (jget data "thread_id")
                          "reply_to_message_id" (jget data "reply_to"))))
         (loop for i from 1
               for chunk in chunks
               do (let ((h (copy-hash-table base)))
                    (setf (gethash "text" h)
                          (if (> n 1) (format nil "~a (~a/~a)" chunk i n) chunk))
                    (send-payload "sendMessage" h))))
       t))
    ((equal topic "telegram/typing")
     ;; Best effort: a lost typing action is not worth a retry.
     (ignore-errors (api "sendChatAction" (dict "chat_id" (jget data "chat_id")
                                                "action" "typing")))
     t)
    ;; telegram/* also matches telegram/inbound, which this connector
    ;; publishes itself: nothing to deliver, so done - nil would retry forever.
    (t t)))

;;; --- inbound -------------------------------------------------------------------

(defvar *offset* 0)

(defun inbound-loop ()
  "Long-poll getUpdates; each message -> telegram/inbound. Never raises."
  (loop
    (handler-case
        (let ((updates (api "getUpdates" (dict "timeout" 25 "offset" (1+ *offset*)))))
          (when (vectorp updates)
            (loop for u across updates
                  for msg = (jget u "message")
                  do (setf *offset* (max *offset* (or (jget u "update_id") 0)))
                     (when msg
                       (eventbus:publish "telegram/inbound"
                                         (dict "update_id" (jget u "update_id")
                                               "chat_id" (jget msg "chat" "id")
                                               "text" (jget msg "text")
                                               "from" (jget msg "from")
                                               "message_id" (jget msg "message_id")))))))
      (error (e)
        (format *error-output* "chan-telegram inbound: ~a~%" e)
        (sleep 5)))))

;;; --- self-registration -------------------------------------------------------

(chanreg:register "telegram" "telegram/*" #'outbound-dispatch #'inbound-loop)
