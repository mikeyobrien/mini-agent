;;;; channels.d/telegram.lisp -- Telegram connector. Self-registering.
;;;; Outbound: any event on telegram/outbound -> sendMessage.
;;;;   payload: {"text": "...", "chat_id": N}   (thread/thread_id optional)
;;;; Inbound: getUpdates long-poll -> publish "telegram/inbound".
;;;; Token: TELEGRAM_BOT_TOKEN env, or .env.telegram next to the daemon.

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

(defun token ()
  (or (getenv "TELEGRAM_BOT_TOKEN") (env-file-token)
      (error "chan-telegram: no TELEGRAM_BOT_TOKEN (env or .env.telegram)")))

(defun api (method &optional payload)
  "POST to the Bot API. Returns the parsed result or signals."
  (let* ((json (and payload (com.inuoe.jzon:stringify payload)))
         (args (list "curl" "-s" "--max-time" "30"
                     (format nil "https://api.telegram.org/bot~a/~a"
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

;;; --- outbound ----------------------------------------------------------------

(defun jget (h k) (and (hash-table-p h) (gethash k h)))

(defun outbound-dispatch (id ts topic data)
  "telegram/* -> Bot API. Returns T when handled; nil/raise => retry."
  (declare (ignore id ts))
  (cond
    ((equal topic "telegram/outbound")
     (let ((text (jget data "text"))
           (chat (jget data "chat_id")))
       (unless (and text chat)
         (error "telegram/outbound needs text+chat_id"))
       (api "sendMessage"
            (let ((h (make-hash-table :test 'equal)))
              (setf (gethash "chat_id" h) chat
                    (gethash "text" h) text
                    (gethash "parse_mode" h) "Markdown")
              (let ((thread (jget data "thread_id")))
                (when thread
                  (setf (gethash "message_thread_id" h) thread)))
              h)))
     t)
    (t nil)))          ; other telegram/* topics: nothing to do, success

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
                                       (gethash "message_id" h) (jget msg "id"))
                                 h)))))))
      (error (e)
        (format *error-output* "chan-telegram inbound: ~a~%" e)
        (sleep 5)))))

;;; --- self-registration ---------------------------------------------------------

(register!)
