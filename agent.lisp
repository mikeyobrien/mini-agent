;;;; mini-agent — the bare-minimum agent loop from minimal-agent.com, in Common Lisp.
;;;;
;;;; query LM -> tool call -> run -> append result -> repeat.
;;;;
;;;; One tool: bash. Stateless process per action. Linear list history.
;;;; Errors are appended as tool messages so the model self-corrects.
;;;;
;;;; Run:  sbcl --script run.lisp "fix the failing test"
;;;;       sbcl --script run.lisp              (prompts for a task)
;;;; Requires: SBCL; shells out to curl for HTTP transport only. No ASDF deps.

(require :uiop)

(defpackage :mini-agent
  (:use :cl)
  (:import-from #:uiop #:getenv #:command-line-arguments))

(in-package :mini-agent)

;;; --- Config -----------------------------------------------------------------
(defparameter *base-url* (or (uiop:getenv "MINI_AGENT_BASE_URL") "http://spark-1:8888/v1"))
(defparameter *model*    (or (uiop:getenv "MINI_AGENT_MODEL") "GLM-5.3-Flash-EXL3"))
;; 0 = no step cap, mirroring mini-swe-agent's mini.yaml default.
(defparameter *max-steps*
  (parse-integer (or (uiop:getenv "MINI_AGENT_MAX_STEPS") "0")))
(defparameter *step-timeout*
  (parse-integer (or (uiop:getenv "MINI_AGENT_TIMEOUT") "120")))
;;; High thinking (operator pref): enabled, bounded budget.
(defparameter *thinking* "\"enable_thinking\":true,\"thinking_budget\":16384")

(defparameter *max-output* 20000)

;;; ---------------------------------------------------------------------------
;;; JSON encoding

(defun json-escape (s)
  (with-output-to-string (out)
    (loop for ch across (the string (string s)) do
      (case ch
        (#\"  (write-string "\\\"" out))
        (#\\  (write-string "\\\\" out))
        (#\Newline (write-string "\\n" out))
        (#\Return  (write-string "\\r" out))
        (#\Tab     (write-string "\\t" out))
        (t (write-char ch out))))))

(defun jstr (x) (format nil "\"~a\"" (json-escape (princ-to-string x))))

(defmacro jobj (&body slots)
  ;; (jobj ("key" value) ...) -> {"key":V,...}; values evaluate to JSON fragments
  (let ((n (length slots)))
    `(with-output-to-string (s)
       (write-char #\{ s)
       ,@(loop for slot in slots
               for i from 0
               append (destructuring-bind (k v) slot
                        `((progn (write-string ,(format nil "\"~a\":" k) s)
                                 (princ ,v s))
                          ,@(when (< i (1- n)) `((write-char #\, s))))))
       (write-char #\} s))))

(defun jlist (frags) (format nil "[~{~a~^,~}]" frags))

(defun tool-schema ()
  (jobj ("type" (jstr "function"))
        ("function" (jobj
          ("name" (jstr "bash"))
          ("description" (jstr "Run a shell command in a fresh subshell. No state persists: prefix cd / export every time."))
          ("parameters" (jobj
            ("type" (jstr "object"))
            ("properties" (jobj ("command" (jobj ("type" (jstr "string"))))))
            ("required" (jlist (list (jstr "command"))))))))))

;;; ---------------------------------------------------------------------------
;;; JSON decoding — smallest parser that reads chat-completions responses.
;;; Strings -> string, numbers -> number, true/false -> t/nil, null -> :null,
;;; objects -> hash-table (equal), arrays -> list.

(defun json-parse (s) (%value (coerce s 'simple-string) 0))

(defun %ws (s i)
  (do ((j i (1+ j)))
      ((or (>= j (length s))
           (not (member (char s j) '(#\Space #\Newline #\Tab #\Return) :test #'char=)))
       j)))

(defun %value (s i)
  (let ((p (%ws s i)))
    (when (>= p (length s)) (error "json: unexpected end of input"))
    (case (char s p)
      (#\{ (%object s p))
      (#\[ (%array  s p))
      (#\" (%string s p))
      (#\t (values t     (+ p 4)))
      (#\f (values nil   (+ p 5)))
      (#\n (values :null (+ p 4)))
      (t   (%number s p)))))

(defun %string (s i)
  ;; i points at the opening quote; returns content and index past closing quote.
  (let ((buf (make-string-output-stream)) (j (1+ i)) done)
    (loop until done do
      (let ((c (char s j)))
        (cond
          ((char= c #\") (setf done t))
          ((char= c #\\)
           (incf j)
           (case (char s j)
             (#\" (write-char #\" buf))
             (#\\ (write-char #\\ buf))
             (#\/ (write-char #\/ buf))
             (#\n (write-char #\Newline buf))
             (#\r (write-char #\Return buf))
             (#\t (write-char #\Tab buf))
             (#\b (write-char #\Backspace buf))
             (#\f (write-char #\Page buf))
             (#\u (let ((cp (parse-integer s :start (1+ j) :end (+ 4 j) :radix 16)))
                    (write-char (code-char cp) buf)
                    (incf j 3)))))
          (t (write-char c buf))))
      (incf j))
    (values (get-output-stream-string buf) j)))

(defun %object (s i)
  (let ((h (make-hash-table :test 'equal)) (j (1+ i)))
    (setf j (%ws s j))
    (if (and (< j (length s)) (char= (char s j) #\}))
        (values h (1+ j))
        (loop
          (multiple-value-bind (key kj) (%string s j)
            (let ((colon (%ws s kj)))
              (assert (char= (char s colon) #\:))
              (multiple-value-bind (v vj) (%value s (1+ colon))
                (setf (gethash key h) v)
                (setf j (%ws s vj))
                (case (char s j)
                  (#\, (setf j (%ws s (1+ j))))
                  (#\} (return-from %object (values h (1+ j))))
                  (t (error "json: bad object syntax at ~a" j))))))))))

(defun %array (s i)
  (let (acc (j (1+ i)))
    (setf j (%ws s j))
    (if (and (< j (length s)) (char= (char s j) #\]))
        (values nil (1+ j))
        (loop
          (multiple-value-bind (v vj) (%value s j)
            (push v acc)
            (setf j (%ws s vj))
            (case (char s j)
              (#\, (incf j))
              (#\] (return-from %array (values (nreverse acc) (1+ j))))
              (t (error "json: bad array syntax at ~a" j))))))))

(defun %number (s i)
  (let ((j i))
    (when (char= (char s j) #\-) (incf j))
    (loop while (and (< j (length s))
                     (find (char s j) "0123456789.eE+-" :test #'char=))
          do (incf j))
    (values (read-from-string s nil nil :start i :end j) j)))

;;; Accessors
(defun ht-get (h k &optional dflt) (gethash k h dflt))
(defun ensure-list (x) (if (consp x) x (and x (list x))))
(defun jmap (fn list) (mapcar fn list))

;;; ---------------------------------------------------------------------------
;;; HTTP transport: curl for the wire, Lisp for everything else.

(defun http-post-json (url body)
  (uiop:with-temporary-file (:pathname req)
    (uiop:with-temporary-file (:pathname out)
      (with-open-file (f req :direction :output :if-exists :supersede)
        (write-string body f))
      (let ((code (uiop:run-program
                   (list "curl" "-s" "-o" (namestring out) "-w" "%{http_code}"
                         "--max-time" "300"
                         "-H" "Content-Type: application/json"
                         "--data-binary" (format nil "@~a" (namestring req))
                         url)
                   :output :string)))
        (let ((text (uiop:read-file-string out)))
          (unless (string= (string-trim '(#\Space #\Newline #\Return) code) "200")
            (error "HTTP ~a: ~a" (string-trim '(#\Space #\Newline) code)
                   (subseq text 0 (min 300 (length text)))))
          text)))))

;;; ---------------------------------------------------------------------------
;;; Agent loop

(defun build-request (history)
  ;; history: list of alists — ((:role . "assistant") (:content . "...) (:tool-calls . <json string>))
  ;; or ((:role . "tool") (:tool-call-id . "...") (:content . "..."))
  (let ((msgs
          (loop for m in history collect
            (let ((role (cdr (assoc :role m)))
                  (content (cdr (assoc :content m)))
                  (tcid   (cdr (assoc :tool-call-id m)))
                  (tcalls (cdr (assoc :tool-calls m))))
              (cond
                (tcalls (jobj ("role" (jstr role))
                              ("content" (if (stringp content) (jstr content) "null"))
                              ("tool_calls" (the string tcalls))))
                (tcid   (jobj ("role" (jstr "tool"))
                              ("tool_call_id" (jstr tcid))
                              ("content" (jstr (or content "")))))
                (t      (jobj ("role" (jstr role))
                              ("content" (jstr (or content ""))))))))))
    (jobj ("model" (jstr *model*))
          ("messages" (jlist
                          (cons (jobj ("role" (jstr "system"))
                                      ("content" (jstr (slurp-system-md))))
                                msgs)))
          ("tools" (jlist (list (tool-schema))))
          ("tool_choice" (jstr "auto"))
          ("chat_template_kwargs" (format nil "{~a}" *thinking*)))))

(defun query-lm (history)
  (let* ((body (build-request history))
         (text (http-post-json (format nil "~a/chat/completions" *base-url*) body))
         (resp (json-parse text))
         (choices (ht-get resp "choices")))
    (when (or (null choices) (zerop (length choices)))
      (error "no choices in response: ~a" (subseq text 0 (min 200 (length text)))))
    (ht-get (elt choices 0) "message")))

(defun truncate-output (s)
  ;; head+tail elision, mini-swe-agent observation style: 10k head + 10k tail
  (cond
    ((null s) "(no output)")
    ((<= (length s) *max-output*) s)
    (t (let ((head 10000) (tail 10000))
         (format nil "~a~%~%...~a chars elided...~%~%~a"
                 (subseq s 0 head)
                 (- (length s) head tail)
                 (subseq s (- (length s) tail)))))))

(defun execute (cmd)
  "Stateless subprocess per action, like mini-swe-agent."
  (handler-case
      (let ((output (make-string-output-stream)))
        (uiop:run-program
         (list "bash" "-c" cmd)
         :output output
         :error-output output
         :input nil)
        (truncate-output (string-right-trim "\n" (get-output-stream-string output))))
    (error (e) (format nil "Error: ~a" e))))

(defun assistant-message-json (msg)
  "Re-encode the assistant message for the next request round-trip."
  (let ((content (ht-get msg "content"))
        (calls   (ht-get msg "tool_calls")))
    (if calls
        (jobj ("role" "assistant")
              ("content" (if (and (stringp content) (plusp (length content)))
                                (jstr content) "null"))
              ("tool_calls" (jlist
                                (loop for c in (ensure-list calls) collect
                                  (let ((fn (ht-get c "function")))
                                    (jobj ("id" (jstr (ht-get c "id")))
                                          ("type" (jstr "function"))
                                          ("function" (jobj
                                            ("name" (jstr (ht-get fn "name")))
                                            ("arguments" (jstr (ht-get fn "arguments")))))))))))
        (jobj ("role" "assistant")
              ("content" (if (stringp content) (jstr content) "null"))))))

(defun run (task)
  (let ((history
          (list (list (cons :role "user") (cons :content task)))))
    (loop for step from 1 do
      (let* ((msg (query-lm history))
             (tcalls (ht-get msg "tool_calls"))
             (encoded (and tcalls (assistant-message-json-toolcalls msg))))
        ;; append assistant turn verbatim (canonical tool_calls when present)
        (setf history
              (append history
                      (list (list (cons :role "assistant")
                                  (cons :content (ht-get msg "content"))
                                  (cons :tool-calls encoded)))))
        (let ((calls (remove-if-not #'tool-callsp (ensure-list tcalls))))
          (cond
            ;; no tool calls => final answer
            ((null calls)
             (format t "~a~%" (or (ht-get msg "content") "(empty)"))
             (return-from run))
            (t
             (dolist (c calls)
               (let* ((fn (ht-get c "function"))
                      (args (and (ht-get fn "arguments")
                                 (ignore-errors (json-parse (ht-get fn "arguments")))))
                              (cmd (or (and (hash-table-p args) (ht-get args "command")) "")))
                 (format t "[step ~a] $ ~a~%" step cmd)
                 (let ((out (execute cmd)))
                   (setf history
                         (append history
                                 (list (list (cons :role "tool")
                                             (cons :tool-call-id (ht-get c "id"))
                                             (cons :content out)))))))))))))
    ;; loop ended without final answer
    (when (plusp *max-steps*)
      (format t "(step budget ~a exhausted)~%" *max-steps*))))

(defun tool-callsp (x) (and (hash-table-p x) (ht-get x "function" nil)))

(defun assistant-message-json-toolcalls (msg)
  ;; Re-encode real tool calls canonically; NIL when absent/empty/malformed.
  (let ((calls (remove-if-not #'tool-callsp (ensure-list (ht-get msg "tool_calls")))))
    (when calls
      (jlist
       (loop for c in calls collect
             (let ((fn (ht-get c "function")))
               (jobj ("id" (jstr (ht-get c "id")))
                     ("type" (jstr "function"))
                     ("function" (jobj
                                   ("name" (jstr (ht-get fn "name")))
                                   ("arguments" (jstr (ht-get fn "arguments"))))))))))))

(defun slurp-system-md ()
  (let ((path (merge-pathnames "SYSTEM.md" (uiop:getcwd))))
    (if (probe-file path)
        (uiop:read-file-string path)
        (error "SYSTEM.md not found in ~a" (uiop:getcwd)))))

(defun main ()
  (let ((args (command-line-arguments)))
    (let ((task (if args (format nil "~{~a~^ ~}" args)
                    (progn
                      (princ "task: ")
                      (finish-output)
                      (read-line)))))
      (run task)
      (uiop:quit 0))))

(when (uiop:getenv "MINI_AGENT_AUTORUN") (main))
