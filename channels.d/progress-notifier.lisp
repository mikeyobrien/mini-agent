;;;; channels.d/progress-notifier.lisp -- optional progress pings (P1 #7).
;;;; Tails agent/step and pings the step's chat (the chat_id agent-responder
;;;; stamps on its runs) at most once per 45s: "… step 3: curl -s ...".
;;;; A step whose run has already answered is skipped: a ping must never
;;;; trail the answer. Delete this file to disable; no other edits.

(defpackage :progress-notifier
  (:use :cl)
  (:import-from :eventbus #:dict #:jget)
  (:export #:boot))

(in-package :progress-notifier)

(defparameter *every-seconds* 45 "Min seconds between pings to one chat.")
(defparameter *max-cmd* 80)

(defvar *last-ping* (make-hash-table :test 'equal)
  "chat -> universal time of its last ping. Only the tail thread touches it.")

(defun throttled? (chat)
  "T if CHAT was pinged under *every-seconds* ago; else records now, NIL."
  (let ((now (get-universal-time))
        (last (gethash chat *last-ping*)))
    (if (or (null last) (>= (- now last) *every-seconds*))
        (progn (setf (gethash chat *last-ping*) now) nil)
        t)))

(defun answered-after-p (chat id)
  "Did CHAT's run finish after event ID?"
  (find chat (eventbus:since id "agent/done")
        :key (lambda (e) (jget (getf e :data) "chat_id")) :test #'equal))

(defun handle (event)
  (let* ((data (getf event :data))
         (chat (jget data "chat_id"))
         (step (jget data "step"))
         (cmd (or (jget data "command") "")))
    (when (and chat step (plusp (length cmd))
               (not (answered-after-p chat (getf event :id)))
               (not (throttled? chat)))
      (eventbus:publish "telegram/outbound"
                        (dict "chat_id" chat
                              "text" (format nil "… step ~a: ~a" step
                                             (subseq cmd 0 (min *max-cmd* (length cmd)))))))))

(defun boot ()
  (format *error-output* "progress-notifier: watching agent/step~%")
  (eventbus:tail "agent/step" #'handle :name "progress-notifier"))

(chanreg:add-boot-hook "progress-notifier" #'boot)
