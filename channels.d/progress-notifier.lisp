;;;; channels.d/progress-notifier.lisp -- optional progress pings (P1 #7).
;;;; Tails agent/step off the bus; pings the chat whose task is in flight at
;;;; most once per 45s: "... step 3: curl -s ...". Delete this file (or the
;;;; *CURRENT-CHAT* write in agent-responder) to disable; no core edits.

(defpackage :progress-notifier
  (:use :cl)
  (:export #:boot))

(in-package :progress-notifier)

(defparameter *poll-seconds* 3)
(defparameter *every-seconds* 45 "Min seconds between pings to one chat.")
(defparameter *max-cmd* 80)

(defvar *last-ping* (make-hash-table :test 'eql))

(defun responder (name)
  (and (find-package :agent-responder)
       (find-symbol name :agent-responder)))

(defun throttled? (chat)
  "T if CHAT was pinged under *every-seconds* ago; else records now, NIL."
  ;; single consumer thread: no lock needed
  (let ((now (get-universal-time))
        (last (gethash chat *last-ping*)))
    (if (or (null last) (>= (- now last) *every-seconds*))
        (progn (setf (gethash chat *last-ping*) now) nil)
        t)))

(defun ping! (chat step cmd)
  (let ((pub (find-symbol "PUBLISH" :eventbus)))
    (when pub
      (funcall pub "telegram/outbound"
               (let ((h (make-hash-table :test 'equal)))
                 (setf (gethash "chat_id" h) chat
                       (gethash "text" h)
                       (format nil "… step ~a: ~a" step
                               (subseq cmd 0 (min *max-cmd* (length cmd)))))
                 h)))))

(defun loop! (cursor)
  (loop
    (handler-case
        (progn
          (let ((since (find-symbol "SINCE" :eventbus))
                (chat-sym (responder "*CURRENT-CHAT*")))
            (when since
              (let ((events (funcall since cursor "agent/step"))
                    (chat (and chat-sym (symbol-value chat-sym))))
                (dolist (e events)
                  (let* ((data (getf e :data))
                         (step (gethash "step" data))
                         (cmd (or (gethash "command" data) "")))
                    (when (and chat step (plusp (length cmd)) (not (throttled? chat)))
                      (ping! chat step cmd))))
                (let ((last (and events (getf (car (last events)) :id))))
                  (when (and last (> last cursor)) (setf cursor last)))))))
      (error (e)
        (format *error-output* "progress-notifier: ~a~%" e)))
    (sleep *poll-seconds*)))

(defun boot ()
  (unless (and (find-package :eventbus) (responder "*CURRENT-CHAT*"))
    (format *error-output* "progress-notifier: no bus/responder state, idle~%")
    (return-from boot))
  (let ((max-id (find-symbol "MAX-ID" :eventbus)))
    (format *error-output* "progress-notifier: watching agent/step~%")
    (loop! (if max-id (funcall max-id "agent/step") 0))))

(when (find-package :chanreg)
  (push #'progress-notifier:boot
        (symbol-value (find-symbol "*BOOT-HOOKS*" :chanreg))))
