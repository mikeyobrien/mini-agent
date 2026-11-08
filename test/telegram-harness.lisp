;;;; telegram-harness.lisp — end-to-end evaluation of the Telegram experience.
;;;;
;;;; Boots the real eventd (all channels.d/ connectors) in a scratch dir and
;;;; points it at an in-process fake: one HTTP server playing both the Telegram
;;;; Bot API and the OpenAI-compatible LM. Scenarios inject user messages via
;;;; getUpdates and judge what the user would see: every Bot API call is
;;;; recorded with a timestamp.
;;;;
;;;;   timeout 300 sbcl --script test/telegram-harness.lisp            ; all
;;;;   timeout 300 sbcl --script test/telegram-harness.lisp basic chunks
;;;;   HARNESS_LIVE=1 timeout 600 sbcl --script test/telegram-harness.lisp
;;;;     ; real LM from .env.agent, scenario "live" only
;;;;
;;;; Exit 0 = every CHECK passed. UX lines (latencies vs targets) are reported,
;;;; never fatal: they grade the experience, the checks guard behavior.

(require :uiop)
(require :sb-bsd-sockets)
(require :sb-posix)
(let ((setup (or (probe-file (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname)))
                 (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))))
  (load setup))
(funcall (find-symbol "QUICKLOAD" :ql) :com.inuoe.jzon :silent t)

(defpackage :tg-harness (:use :cl) (:import-from :com.inuoe.jzon #:parse #:stringify))
(in-package :tg-harness)

(defvar *repo* (uiop:pathname-parent-directory-pathname
                (uiop:pathname-directory-pathname *load-truename*)))
(defvar *live* (equal (uiop:getenv "HARNESS_LIVE") "1"))

(defun obj (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))
(defun jget (h &rest ks)
  (dolist (k ks h) (setf h (and (hash-table-p h) (gethash k h)))))

(defvar *t0* (get-internal-real-time))
(defun now () (/ (- (get-internal-real-time) *t0*) internal-time-units-per-second 1.0))

;;; --- fake server state --------------------------------------------------------

(defvar *lock* (sb-thread:make-mutex :name "fake"))
(defvar *calls* nil "Recorded Bot API calls, newest first: (time method payload ok).")
(defvar *updates* nil "Injected updates, oldest first.")
(defvar *polls* 0 "getUpdates calls seen: the connector's inbound loop is live.")
(defvar *msg-id* 9000)
(defvar *send-rule* (constantly nil)
  "(lambda (payload)) -> nil to accept a sendMessage, or an error description.")
(defvar *lm-requests* nil "Chat-completion request bodies, newest first.")
(defvar *lm-scripts* nil
  "(marker . steps): a task containing MARKER gets STEPS, one per LM call.
Step plists: (:sleep s :tool cmd) | (:sleep s :answer text) | (:status code).")

(defun record (method payload ok)
  (sb-thread:with-mutex (*lock*) (push (list (now) method payload ok) *calls*)))

(defun calls (chat &key method (after 0))
  "Calls to CHAT, oldest first."
  (sb-thread:with-mutex (*lock*)
    (reverse (remove-if-not (lambda (c)
                              (and (equal (jget (third c) "chat_id") chat)
                                   (or (null method) (equal method (second c)))
                                   (>= (first c) after)))
                            *calls*))))

(defun sends (chat &key ok-only (after 0))
  (remove-if (lambda (c) (and ok-only (not (fourth c))))
             (calls chat :method "sendMessage" :after after)))

(defun text-of (call) (or (jget (third call) "text") ""))

;;; --- fake Bot API + LM routes ---------------------------------------------------

(defun bot-route (method payload)
  (cond
    ((equal method "getUpdates")
     (sb-thread:with-mutex (*lock*) (incf *polls*))
     (let ((offset (or (jget payload "offset") 0)))
       (flet ((pending ()
                (sb-thread:with-mutex (*lock*)
                  (remove-if (lambda (u) (< (jget u "update_id") offset)) *updates*))))
         (loop repeat 10 until (pending) do (sleep 0.1))
         (values 200 (obj "ok" t "result" (coerce (pending) 'vector))))))
    ((equal method "sendMessage")
     (let ((err (funcall *send-rule* payload)))
       (record method payload (not err))
       (if err
           (values 400 (obj "ok" nil "error_code" 400 "description" err))
           (values 200 (obj "ok" t "result"
                            (obj "message_id" (sb-thread:with-mutex (*lock*) (incf *msg-id*))))))))
    (t (record method payload t)
       (values 200 (obj "ok" t "result" t)))))

(defun lm-route (req)
  (sb-thread:with-mutex (*lock*) (push req *lm-requests*))
  (let* ((msgs (coerce (or (jget req "messages") #()) 'list))
         (task (format nil "~{~a~}" (loop for m in msgs
                                          when (equal (jget m "role") "user")
                                            collect (or (jget m "content") ""))))
         (step (count "tool" msgs :key (lambda (m) (jget m "role")) :test #'equal))
         (script (cdr (find-if (lambda (s) (search (car s) task)) *lm-scripts*)))
         (spec (or (nth step script) '(:answer "ok"))))
    (when (getf spec :sleep) (sleep (getf spec :sleep)))
    (if (getf spec :status)
        (values (getf spec :status) (obj "error" "scripted LM failure"))
        (values 200
                (obj "model" "fake"
                     "choices"
                     (vector
                      (obj "index" 0
                           "message"
                           (if (getf spec :tool)
                               (obj "role" "assistant" "content" ""
                                    "tool_calls"
                                    (vector (obj "id" (format nil "call_~a" step)
                                                 "type" "function"
                                                 "function"
                                                 (obj "name" "bash"
                                                      "arguments"
                                                      (stringify (obj "command" (getf spec :tool)))))))
                               (obj "role" "assistant" "content" (getf spec :answer)))))
                     "usage" (obj "prompt_tokens" 10 "completion_tokens" 5))))))

(defun route (path body)
  (let ((payload (and (plusp (length body)) (ignore-errors (parse body)))))
    (cond
      ((search "/chat/completions" path) (lm-route payload))
      ((uiop:string-prefix-p "/bot" path)
       (bot-route (subseq path (1+ (position #\/ path :from-end t))) payload))
      (t (values 404 (obj "ok" nil))))))

;;; --- minimal HTTP/1.1 server (one request per connection) ---------------------

(defun read-crlf-line (in)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte in nil nil)
          until (or (null b) (= b 10))
          unless (= b 13) do (vector-push-extend b bytes))
    (sb-ext:octets-to-string bytes :external-format :utf-8)))

(defun write-ascii (out s)
  (write-sequence (sb-ext:string-to-octets s :external-format :latin-1) out))

(defun serve (sock)
  (unwind-protect
       (handler-case
           (let* ((st (sb-bsd-sockets:socket-make-stream
                       sock :input t :output t :element-type '(unsigned-byte 8)
                            :buffering :full))
                  (crlf (coerce '(#\Return #\Newline) 'string))
                  (path (second (uiop:split-string (read-crlf-line st))))
                  (len 0) (expect nil))
             (loop for h = (read-crlf-line st)
                   until (string= h "")
                   do (let ((k (string-downcase (subseq h 0 (or (position #\: h) 0))))
                            (v (string-trim " " (subseq h (1+ (or (position #\: h) -1))))))
                        (cond ((string= k "content-length") (setf len (parse-integer v)))
                              ((string= k "expect") (setf expect t)))))
             (when expect   ; curl waits on 100-continue for bodies > 1KB
               (write-ascii st (format nil "HTTP/1.1 100 Continue~a~a" crlf crlf))
               (force-output st))
             (let ((buf (make-array len :element-type '(unsigned-byte 8))))
               (read-sequence buf st)
               (multiple-value-bind (status reply)
                   (route path (sb-ext:octets-to-string buf :external-format :utf-8))
                 (let ((bytes (sb-ext:string-to-octets (stringify reply) :external-format :utf-8)))
                   (write-ascii st (format nil "HTTP/1.1 ~a X~aContent-Type: application/json~aContent-Length: ~a~aConnection: close~a~a"
                                           status crlf crlf (length bytes) crlf crlf crlf))
                   (write-sequence bytes st)
                   (force-output st)))))
         (error (e) (format *error-output* "fake: ~a~%" e)))
    (sb-bsd-sockets:socket-close sock)))

(defun start-server ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
    (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen s 64)
    (sb-thread:make-thread
     (lambda ()
       (loop (let ((c (sb-bsd-sockets:socket-accept s)))
               (sb-thread:make-thread (lambda () (serve c)) :name "fake-conn"))))
     :name "fake-accept")
    (nth-value 1 (sb-bsd-sockets:socket-name s))))

;;; --- daemon under test ----------------------------------------------------------

(defvar *dir* nil)
(defvar *proc* nil)

(defun write-file (path text)
  (with-open-file (f path :direction :output :if-exists :supersede) (write-string text f)))

(defun boot-daemon (port)
  (setf *dir* (uiop:ensure-directory-pathname
               (format nil "~a/mini-agent-tg-~a" (string-right-trim "/" (or (uiop:getenv "TMPDIR") "/tmp"))
                       (get-universal-time))))
  (ensure-directories-exist *dir*)   ; eventd's cwd: bus, deliveries, state/
  (write-file (merge-pathnames ".env.agent" *dir*)
              (if *live*
                  (uiop:read-file-string (merge-pathnames ".env.agent" *repo*))
                  (format nil "MINI_AGENT_BASE_URL=http://127.0.0.1:~a/v1~%MINI_AGENT_MODEL=fake~%MINI_AGENT_MAX_STEPS=8~%MINI_AGENT_TIMEOUT=20~%MINI_AGENT_HTTP_TIMEOUT=30~%" port)))
  (let ((env (append (list (format nil "TELEGRAM_API_BASE=http://127.0.0.1:~a" port)
                           "TELEGRAM_BOT_TOKEN=harness")
                     (remove-if (lambda (kv)
                                  (some (lambda (p) (uiop:string-prefix-p p kv))
                                        '("TELEGRAM_" "MINI_AGENT_" "EVENTD_" "CHANREG_")))
                                (sb-ext:posix-environ)))))
    (setf *proc* (sb-ext:run-program "sbcl" (list "--script" (namestring (merge-pathnames "src/eventd.lisp" *repo*)))
                                     :search t :wait nil :input nil
                                     :directory (namestring *dir*) :environment env
                                     :output (namestring (merge-pathnames "eventd.out" *dir*))
                                     :error (namestring (merge-pathnames "eventd.err" *dir*))
                                     :if-output-exists :supersede :if-error-exists :supersede)))
  ;; Ready = a probe message gets its threaded final reply (acks and pings
  ;; carry no reply_to; works for fake and live LMs). The responder tails from
  ;; max-id at boot, so probes sent before it is up are dropped: keep sending
  ;; until one lands, then wait for its answer so the worker is idle.
  (push '("[[probe]]" (:answer "PROBE-OK")) *lm-scripts*)
  (unless (wait-until (if *live* 900 120)
                      (lambda ()
                            ;; every accepted probe (its ack quotes it) answered
                            (or (let ((ok (sends 999 :ok-only t)))
                                  (and ok (= (count-if (lambda (c) (and (search "[[probe]]" (text-of c))
                                                                        (not (jget (third c) "reply_to_message_id"))))
                                                       ok)
                                             (count-if (lambda (c) (jget (third c) "reply_to_message_id")) ok))))
                                (progn (unless (sends 999) (say 999 "[[probe]] ready?"))
                                       (sleep 10)   ; don't double-probe a slow boot
                                       nil))))
    (error "daemon not answering the probe; see ~a" (merge-pathnames "eventd.err" *dir*))))

(defun stop-daemon ()
  (when (and *proc* (sb-ext:process-alive-p *proc*))
    (sb-ext:process-kill *proc* 15)
    (sb-ext:process-wait *proc*)))

;;; --- driving + judging ------------------------------------------------------------

(defun wait-until (secs pred)
  (loop with deadline = (+ (now) secs)
        for v = (funcall pred)
        until (or v (> (now) deadline))
        do (sleep 0.1)
        finally (return v)))

(defvar *update-id* 5000)

(defun say (chat text &key (update-id (incf *update-id*)))
  "User sends TEXT in CHAT. Returns (values message-id sent-at)."
  (let ((mid (+ 100 update-id)))
    (sb-thread:with-mutex (*lock*)
      (setf *updates* (append *updates*
                              (list (obj "update_id" update-id
                                         "message" (obj "message_id" mid "text" text
                                                        "chat" (obj "id" chat "type" "private")
                                                        "from" (obj "id" 1 "first_name" "harness")))))))
    (values mid (now))))

(defun answer-call (chat marker)
  (find-if (lambda (c) (search marker (text-of c))) (sends chat :ok-only t)))

(defvar *fails* 0)
(defvar *scenario* "")

(defun check (name ok &optional detail)
  (unless ok (incf *fails*))
  (format t "  ~:[FAIL~;PASS~] ~a~@[  (~a)~]~%" ok name (and (not ok) detail)))

(defun ux (name value target)
  (format t "  UX   ~a: ~:[n/a~;~:*~,1fs~] (target ≤~,1fs) ~:[MISS~;ok~]~%"
          name value target (and value (<= value target))))

(defun transcript (chat since)
  (format t "  transcript (chat ~a):~%" chat)
  (let ((typing 0))
    (dolist (c (calls chat :after since))
      (if (equal (second c) "sendChatAction")
          (incf typing)
          (let ((txt (map 'string (lambda (ch) (if (char= ch #\Newline) #\⏎ ch)) (text-of c))))
            (format t "    +~5,1fs ~:[✗~;→~] ~a~@[ reply_to=~a~]: ~a~a~%"
                    (- (first c) since) (fourth c) (second c)
                    (jget (third c) "reply_to_message_id")
                    (subseq txt 0 (min 90 (length txt)))
                    (if (> (length txt) 90) (format nil "… [~a chars]" (length txt)) "")))))
    (format t "    (~a typing actions)~%" typing)))

(defmacro defscenario (name doc &body body)
  `(setf (getf *scenarios* ,name)
         (lambda () (format t "~%== ~(~a~) — ~a~%" ,name ,doc) ,@body)))
(defvar *scenarios* nil)

;;; --- scenarios ----------------------------------------------------------------------

(defscenario :basic "ack, typing, threaded answer, typing stops"
  (push '("[[basic]]" (:sleep 1 :tool "echo harness-basic")
                      (:sleep 6 :answer "ANSWER-BASIC: harness-basic seen"))
        *lm-scripts*)
  (multiple-value-bind (mid t0) (say 101 "[[basic]] say hi")
    (let ((ans (wait-until 60 (lambda () (answer-call 101 "ANSWER-BASIC")))))
      (check "answer delivered" ans "no message containing ANSWER-BASIC in 60s")
      (when ans
        (sleep 10)
        (let* ((ack (first (sends 101 :after t0)))
               (t-ans (first ans))
               (typing (calls 101 :method "sendChatAction" :after t0)))
          (check "ack is the first message and names the task"
                 (and ack (not (eq ack ans)) (search "say hi" (text-of ack)))
                 (and ack (text-of ack)))
          (check "answer is threaded to the user's message"
                 (eql (jget (third ans) "reply_to_message_id") mid))
          (check "typing shown while working (>=2 actions)"
                 (>= (count-if (lambda (c) (< (first c) t-ans)) typing) 2))
          (check "typing stops after the answer"
                 (notany (lambda (c) (> (first c) (+ t-ans 5))) typing)
                 (format nil "~a typing actions >5s after answer"
                         (count-if (lambda (c) (> (first c) (+ t-ans 5))) typing)))
          (check "answer sent exactly once"
                 (= 1 (count-if (lambda (c) (search "ANSWER-BASIC" (text-of c))) (sends 101 :after t0))))
          (check "answer is the model's text alone (no step trace)"
                 (string= (text-of ans) "ANSWER-BASIC: harness-basic seen")
                 (text-of ans))
          (ux "time to ack" (and ack (- (first ack) t0)) 1.0)
          (ux "time to answer beyond LM time (7s)" (- t-ans t0 7) 3.0)))
      (transcript 101 t0))))

(defscenario :progress "multi-step run sends a progress ping"
  (push '("[[progress]]" (:sleep 2 :tool "echo p1") (:sleep 2 :tool "echo p2")
                         (:sleep 2 :tool "echo p3") (:sleep 1 :answer "ANSWER-PROGRESS"))
        *lm-scripts*)
  (multiple-value-bind (mid t0) (say 102 "[[progress]] count to three")
    (declare (ignore mid))
    (let ((ans (wait-until 60 (lambda () (answer-call 102 "ANSWER-PROGRESS")))))
      (check "answer delivered" ans)
      (let ((pings (remove-if-not (lambda (c) (uiop:string-prefix-p "… step" (text-of c)))
                                  (sends 102 :after t0))))
        (check "progress ping before the answer"
               (and ans pings (< (first (first pings)) (first ans))))
        (check "no ping after the answer"
               (and ans (notany (lambda (p) (> (first p) (first ans))) pings)))
        (check "pings throttled (<=1 for a 7s run)" (<= (length pings) 1)
               (format nil "~a pings" (length pings)))))
    (transcript 102 t0)))

(defscenario :chunks "a 9k-char answer arrives as ordered, lossless chunks"
  (let ((answer (format nil "~{~a~^~%~%~}"
                        (loop for i below 30
                              collect (format nil "para-~2,'0d ~a" i
                                              (make-string 290 :initial-element #\x))))))
    (push (list "[[chunks]]" (list :answer answer)) *lm-scripts*)
    (multiple-value-bind (mid t0) (say 103 "[[chunks]] write a lot")
      (wait-until 30 (lambda () (some (lambda (c) (search "para-29" (text-of c))) (sends 103 :after t0))))
      (sleep 3)
      (let* ((parts (remove-if-not (lambda (c) (eql (jget (third c) "reply_to_message_id") mid))
                                   (sends 103 :ok-only t :after t0)))
             (n (length parts))
             (bodies (loop for c in parts for i from 1
                           collect (let ((suffix (format nil " (~a/~a)" i n)) (s (text-of c)))
                                     (and (uiop:string-suffix-p s suffix)
                                          (subseq s 0 (- (length s) (length suffix))))))))
        (check "split into several messages" (> n 1) (format nil "~a part(s)" n))
        (check "every part within Telegram's 4096 limit"
               (every (lambda (c) (<= (length (text-of c)) 4096)) parts))
        (check "parts numbered (i/n) in order" (every #'identity bodies))
        (check "parts reassemble to the exact answer"
               (and (every #'identity bodies) (string= (format nil "~{~a~}" bodies) answer)))
        (check "parts split on paragraph boundaries"
               (every (lambda (b) (or (null b) (uiop:string-prefix-p "para-" b))) bodies))
        (transcript 103 t0)))))

(defscenario :reply-fallback "a rejected reply_to falls back to a plain send, once"
  (push '("[[fallback]]" (:answer "ANSWER-FALLBACK")) *lm-scripts*)
  (setf *send-rule* (lambda (p)
                      (and (eql (jget p "chat_id") 104) (jget p "reply_to_message_id")
                           "Bad Request: message to be replied not found")))
  (unwind-protect
       (multiple-value-bind (mid t0) (say 104 "[[fallback]] answer me")
         (declare (ignore mid))
         (wait-until 30 (lambda () (answer-call 104 "ANSWER-FALLBACK")))
         (sleep 6)   ; long enough for a dispatcher retry to show up
         (let ((tries (remove-if-not (lambda (c) (search "ANSWER-FALLBACK" (text-of c)))
                                     (sends 104 :after t0))))
           (check "answer delivered exactly once"
                  (= 1 (count-if #'fourth tries)) (format nil "~a delivered" (count-if #'fourth tries)))
           (check "two attempts: threaded, then plain"
                  (and (= 2 (length tries))
                       (jget (third (first tries)) "reply_to_message_id")
                       (not (jget (third (second tries)) "reply_to_message_id")))
                  (format nil "~a attempts" (length tries))))
         (transcript 104 t0))
    (setf *send-rule* (constantly nil))))

(defscenario :lm-down "an LM failure is reported to the user, not swallowed"
  (push '("[[down]]" (:status 500)) *lm-scripts*)
  (multiple-value-bind (mid t0) (say 105 "[[down]] anything")
    (declare (ignore mid))
    (let ((err (wait-until 30 (lambda ()
                                (find-if (lambda (c) (search "agent error" (text-of c)))
                                         (sends 105 :ok-only t :after t0))))))
      (check "user told the agent failed" err "no 'agent error' message in 30s")
      (check "failure message is plain text (no HTML entities)"
             (and err (not (search "&#" (text-of err)))))
      (ux "time to failure notice" (and err (- (first err) t0)) 3.0))
    (transcript 105 t0)))

(defscenario :queue "a message sent while busy is acked as queued, answered in order"
  (push '("[[first]]" (:sleep 6 :answer "ANSWER-FIRST")) *lm-scripts*)
  (push '("[[second]]" (:answer "ANSWER-SECOND")) *lm-scripts*)
  (multiple-value-bind (m1 t0) (say 106 "[[first]] slow one")
    (declare (ignore m1))
    (wait-until 10 (lambda () (sends 106 :after t0)))  ; first acked => in flight
    (sleep 2)
    (multiple-value-bind (m2 t1) (say 106 "[[second]] quick one")
      (declare (ignore m2))
      (let ((a2 (wait-until 40 (lambda () (answer-call 106 "ANSWER-SECOND"))))
            (a1 (answer-call 106 "ANSWER-FIRST"))
            (ack2 (find-if (lambda (c) (search "quick one" (text-of c))) (sends 106 :after t1))))
        (check "both answered" (and a1 a2))
        (check "answered in arrival order" (and a1 a2 (< (first a1) (first a2))))
        (check "second message acked as queued, not 'working'"
               (and ack2 (search "queued" (text-of ack2)))
               (and ack2 (text-of ack2)))))
    (transcript 106 t0)))

(defscenario :verbatim "user text and answers survive trimming letter-for-letter"
  ;; Leading/trailing n, t, r are where a "\n"-as-letters trim bites.
  (push '("[[verbatim]]" (:sleep 1 :tool "printf fun") (:answer "tonight, not noon")) *lm-scripts*)
  (multiple-value-bind (mid t0) (say 107 (format nil "  need it in [[verbatim]] time~%"))
    (let ((ans (wait-until 30 (lambda ()
                                (find-if (lambda (c) (eql (jget (third c) "reply_to_message_id") mid))
                                         (sends 107 :ok-only t :after t0))))))
      (check "ack quotes the task exactly (only whitespace trimmed)"
             (some (lambda (c) (search ": need it in [[verbatim]] time" (text-of c))) (sends 107 :after t0)))
      (check "answer ends exactly as the model wrote it"
             (and ans (uiop:string-suffix-p (text-of ans) "tonight, not noon"))
             (and ans (format nil "~s" (subseq (text-of ans) (max 0 (- (length (text-of ans)) 20))))))
      (check "tool output reaches the model intact"
             (some (lambda (req)
                     (some (lambda (m) (and (equal (jget m "role") "tool")
                                            (equal (jget m "content") "fun")))
                           (coerce (or (jget req "messages") #()) 'list)))
                   (sb-thread:with-mutex (*lock*) *lm-requests*))))
    (transcript 107 t0)))

(defscenario :live "real LM round trip (HARNESS_LIVE=1)"
  (multiple-value-bind (mid t0) (say 201 "Reply with exactly the word pong and nothing else.")
    (let ((ans (wait-until 900 (lambda ()
                                 (find-if (lambda (c) (eql (jget (third c) "reply_to_message_id") mid))
                                          (sends 201 :ok-only t :after t0))))))
      (check "answer delivered" ans)
      (check "answer says pong" (and ans (search "pong" (string-downcase (text-of ans)))))
      (let ((ack (first (sends 201 :after t0))))
        (ux "time to ack" (and ack (- (first ack) t0)) 1.0)
        (ux "time to answer" (and ans (- (first ans) t0)) 30.0)))
    (transcript 201 t0)))

;;; --- main -------------------------------------------------------------------------

(defun main ()
  (let* ((args (uiop:command-line-arguments))
         (names (cond (args (mapcar (lambda (a) (intern (string-upcase a) :keyword)) args))
                      (*live* '(:live))
                      (t '(:basic :progress :chunks :reply-fallback :lm-down :queue :verbatim))))
         (port (start-server)))
    (dolist (n names)
      (unless (getf *scenarios* n) (format t "unknown scenario ~(~a~)~%" n) (uiop:quit 2)))
    (format t "fake Bot API + LM on 127.0.0.1:~a; booting eventd…~%" port)
    (unwind-protect
         (progn
           (boot-daemon port)
           (format t "eventd up in ~,1fs (scratch: ~a)~%" (now) (namestring *dir*))
           (dolist (n names) (funcall (getf *scenarios* n))))
      (stop-daemon))
    (format t "~%telegram-harness: ~a failed check(s)~@[; daemon logs in ~a~]~%"
            *fails* (and (plusp *fails*) (namestring *dir*)))
    (uiop:quit (if (zerop *fails*) 0 1))))

(main)
