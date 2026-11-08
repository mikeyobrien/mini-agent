;;;; channels.d/telegram.lisp -- Telegram connector. Self-registering.
;;;; Outbound: any event on telegram/outbound -> sendMessage.
;;;;   payload: {"text": "...", "chat_id": N}   (thread/thread_id optional)
;;;; Inbound: getUpdates long-poll -> publish "telegram/inbound".
;;;; Token: TELEGRAM_BOT_TOKEN env, or .env.telegram next to the daemon.
;;;; TELEGRAM_API_BASE overrides https://api.telegram.org (test harness).

(defpackage :chan-telegram
  (:use :cl)
  (:import-from :uiop #:getenv))

(in-package :chan-telegram)

;;; --- config -----------------------------------------------------------------

(defun env-file-token ()
  "TELEGRAM_BOT_TOKEN from .env.telegram: repo root, cwd, or $HOME."
  (dolist (base (list #P"/Users/rook/mini-agent/"
                      (uiop:getcwd)
                      (and (getenv "HOME")
                           (pathname (concatenate 'string (getenv "HOME") "/")))))
    (let ((path (merge-pathnames ".env.telegram" base)))
      (when (probe-file path)
        (with-open-file (f path)
          (loop for line = (read-line f nil nil) while line
                when (uiop:string-prefix-p "TELEGRAM_BOT_TOKEN=" line)
                  do (return-from env-file-token
                       (string-trim " \"'" (subseq line 19)))))))))

(defun jget (h k) (and (hash-table-p h) (gethash k h)))

(defun token ()
  (or (getenv "TELEGRAM_BOT_TOKEN") (env-file-token)
      (error "chan-telegram: no TELEGRAM_BOT_TOKEN (env or .env.telegram)")))

(defun api (method &optional payload)
  "POST to the Bot API. Returns the parsed result or signals."
  (let* ((json (and payload (com.inuoe.jzon:stringify payload)))
         (args (list "curl" "-s" "--max-time" "30"
                     (format nil "~a/bot~a/~a"
                             (or (getenv "TELEGRAM_API_BASE") "https://api.telegram.org")
                             (token) method))))
    (when json
      (setf args (append args (list "-H" "Content-Type: application/json"
                                    "-d" json))))
    (let ((out (with-output-to-string (s)
                 (uiop:run-program args :output s))))
      (let ((resp (com.inuoe.jzon:parse out)))
        (unless (and (hash-table-p resp) (gethash "ok" resp))
          (error "telegram api ~a failed: ~a" method out))
        (gethash "result" resp)))))


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

(defun typing (chat-id)
  "Best-effort typing indicator; never signals."
  (ignore-errors
    (api "sendChatAction"
         (let ((h (make-hash-table :test 'equal)))
           (setf (gethash "chat_id" h) chat-id
                 (gethash "action" h) "typing")
           h))))

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
              (base (make-hash-table :test 'equal)))
         (setf (gethash "chat_id" base) chat)
         ;; Markdown opt-in via payload; plain text by default - agent output
         ;; with unbalanced _/* broke entities and poisoned retries.
         (let ((pm (jget data "parse_mode")))
           (when pm (setf (gethash "parse_mode" base) pm)))
         (let ((thread (jget data "thread_id")))
           (when thread (setf (gethash "message_thread_id" base) thread)))
         (let ((reply-to (jget data "reply_to")))
           (when reply-to (setf (gethash "reply_to_message_id" base) reply-to)))
         (loop for i from 1
               for chunk in chunks
               do (let ((h (copy-hash-table base)))
                    (setf (gethash "text" h)
                          (if (> n 1) (format nil "~a (~a/~a)" chunk i n) chunk))
                    (send-payload "sendMessage" h))))
       t))
    ((equal topic "telegram/typing")
     (typing (jget data "chat_id"))
     t)
    ;; telegram/* also matches telegram/inbound, which this connector
    ;; publishes itself: nothing to deliver, so done - nil would retry forever.
    (t t)))

(defun register! ()
  (chanreg:register "telegram" "telegram/*" #'outbound-dispatch #'inbound-loop))

;;; --- inbound -------------------------------------------------------------------

(defvar *offset* 0)

(defun inbound-loop ()
  "Long-poll getUpdates; each message -> telegram/inbound. Never raises."
  (loop
    (handler-case
        (let ((updates (api "getUpdates"
                            (let ((h (make-hash-table :test 'equal)))
                              (setf (gethash "timeout" h) 25
                                    (gethash "offset" h) (1+ *offset*))
                              h))))
          (when (and (vectorp updates) (plusp (length updates)))
            (loop for u across updates
                  do (setf *offset* (max *offset* (or (jget u "update_id") 0)))
                  (let ((msg (jget u "message")))
                    (when msg
                      (eventbus:publish "telegram/inbound"
                                        (let ((h (make-hash-table :test 'equal)))
                                          (setf (gethash "update_id" h) (jget u "update_id")
                                                (gethash "chat_id" h)
                                                (jget (jget msg "chat") "id")
                                                (gethash "text" h) (jget msg "text")
                                                (gethash "from" h) (jget msg "from")
                                                (gethash "message_id" h) (jget msg "message_id"))
                                          h)))))))
      (error (e)
        (format *error-output* "chan-telegram inbound: ~a~%" e)
        (sleep 5)))))

;;; --- self-registration -------------------------------------------------------

(register!)
