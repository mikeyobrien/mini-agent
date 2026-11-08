;;;; echo-responder.lisp -- "echo <text>" on telegram/inbound -> <text> back.
;;;; Not a channel: a boot-hook consumer that replies through telegram/outbound.
;;;; A liveness probe for the whole inbound -> bus -> outbound path that needs
;;;; no LM. Tails from boot, so each inbound event is answered once.

(defpackage :echo-responder
  (:use :cl)
  (:import-from :eventbus #:dict #:jget)
  (:export #:boot))

(in-package :echo-responder)

(defun handle (event)
  (let* ((data (getf event :data))
         (text (jget data "text"))
         (chat (jget data "chat_id")))
    (when (and chat (stringp text) (uiop:string-prefix-p "echo " text))
      (eventbus:publish "telegram/outbound"
                        (dict "chat_id" chat "text" (subseq text 5))))))

(defun boot ()
  (format *error-output* "echo-responder: up~%")
  (eventbus:tail "telegram/inbound" #'handle :name "echo-responder"))

(chanreg:add-boot-hook "echo-responder" #'boot)
