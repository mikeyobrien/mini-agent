;;;; mini-agent — the bare-minimum agent loop from minimal-agent.com, in Common Lisp.
;;;;
;;;; query LM -> tool call -> run -> append result -> repeat.
;;;;
;;;; One tool: bash. Stateless process per action. Linear list history.
;;;; Errors are appended as tool messages so the model self-corrects.
;;;;
;;;; Run:  sbcl --script run.lisp "fix the failing test"
;;;;       sbcl --script run.lisp              (prompts for a task)
;;;; Requires: SBCL + quicklisp (~/.quicklisp) for com.inuoe.jzon; curl for HTTP.
;;;; Bootstrap: sbcl --load ~/quicklisp/setup.lisp --script run.lisp "task"

(require :uiop)

(defpackage :mini-agent
  (:use :cl)
  (:import-from #:uiop #:getenv #:command-line-arguments))

(in-package :mini-agent)

;;; --- JSON via com.inuoe.jzon (quicklisp) ------------------------------------
;;; Bootstrapped here so `sbcl --script run.lisp` just works; the quicklisp
;;; load is a no-op once installed.
(eval-when (:load-toplevel :execute)
  (unless (find-package :com.inuoe.jzon)
    (let ((setup (or (probe-file (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname)))
                     (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))))
      (unless (probe-file setup)
        (error "mini-agent needs quicklisp at ~a (for com.inuoe.jzon). Install quicklisp first." setup))
      (load setup))
    (unless (find-package :ql)   ; setup loaded but features checked at read time below
      nil))
  (when (find-package :ql)
    (funcall (find-symbol "QUICKLOAD" :ql) :com.inuoe.jzon))
  (unless (find-package :com.inuoe.jzon)
    (error "com.inuoe.jzon not loadable; run (ql:quickload :com.inuoe.jzon) once.")))

(import 'com.inuoe.jzon:parse :mini-agent)
(import 'com.inuoe.jzon:stringify :mini-agent)

;;; --- Config: environment over hardcode (12factor III) ---------------------------------
;;; Every knob is MINI_AGENT_<NAME>; defaults only ease the zero-config case.

(defun env-str (name dflt) (or (uiop:getenv name) dflt))
(defun env-int (name dflt) (parse-integer (env-str name (princ-to-string dflt))))

;; Where the OpenAI-compatible endpoint lives. No default endpoint: unset
;; MINI_AGENT_BASE_URL means "tell me", not "guess my infra".
(defparameter *base-url* (env-str "MINI_AGENT_BASE_URL" nil))
(defparameter *model*    (env-str "MINI_AGENT_MODEL" nil))

;; Loop limits. 0 = disabled, mirroring mini-swe-agent's mini.yaml.
(defparameter *max-steps*      (env-int "MINI_AGENT_MAX_STEPS" 0))
(defparameter *step-timeout*   (env-int "MINI_AGENT_TIMEOUT" 120))
(defparameter *http-timeout*   (env-int "MINI_AGENT_HTTP_TIMEOUT" 300))
(defparameter *max-output*     (env-int "MINI_AGENT_MAX_OUTPUT" 20000))
(defparameter *trunc-head*     (env-int "MINI_AGENT_TRUNC_HEAD" 10000))
(defparameter *trunc-tail*     (env-int "MINI_AGENT_TRUNC_TAIL" 10000))

;;; Thinking: "enabled" (default budget), "enabled:N" custom budget, "off" disabled.
(defparameter *thinking*
  (let ((raw (env-str "MINI_AGENT_THINKING" "enabled")))
    (cond
      ((member raw '("" "off" "false") :test #'string=) nil)
      ((string= raw "enabled") "\"enable_thinking\":true,\"thinking_budget\":16384")
      ((uiop:string-prefix-p "enabled:" raw)
       (format nil "\"enable_thinking\":true,\"thinking_budget\":~a"
               (ignore-errors (parse-integer (subseq raw 8)))))
      (t raw))))

(defparameter *system-prompt-path* (env-str "MINI_AGENT_SYSTEM_MD" "SYSTEM.md"))

;;; ---------------------------------------------------------------------------
;;; JSON: com.inuoe.jzon (parse/stringify imported above).
;;; Values: objects hash-tables, arrays vectors, true/false t/nil, null :null.

;;; --- Optional event bus -----------------------------------------------------
;;; If eventbus.lisp sits next to agent.lisp, every run emits
;;; agent/start, agent/step, agent/done. Absent file => silent no-op.

(defvar *eventbus* nil)

(defun emit (event payload)
  (when *eventbus*
    (ignore-errors
      (funcall (find-symbol "PUBLISH" :eventbus)
               (format nil "agent/~a" event)
               payload))))

(defvar *source-truename* *load-truename*
  "Where agent.lisp lives, captured at load; *load-truename* is dynamic and
   nil by the time run/load-eventbus execute in a worker thread.")

(defun load-eventbus ()
  (let ((path (merge-pathnames "eventbus.lisp"
                               (or *load-truename* *source-truename*
                                   *default-pathname-defaults*))))
    (when (probe-file path)
      (ignore-errors
        (load path)
        (setf *eventbus* t)
        (funcall (find-symbol "ENSURE-SCHEMA" :eventbus))))))

;;; HTTP transport: curl for the wire, Lisp for everything else.

(defun http-post-json (url body)
  (uiop:with-temporary-file (:pathname req)
    (uiop:with-temporary-file (:pathname out)
      (with-open-file (f req :direction :output :if-exists :supersede)
        (write-string body f))
      (let ((code (uiop:run-program
                   (list "curl" "-s" "-o" (namestring out) "-w" "%{http_code}"
                         "--max-time" (princ-to-string *http-timeout*)
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

(defun dict (&rest kvs)
  "Flat (:a 1 :b 2) -> equal hash-table; jzon stringify renders objects.
Symbols become downcased names sans colon; strings pass through."
  (let ((h (make-hash-table :test 'equal)))
    (loop while kvs
          do (let ((k (pop kvs)) (v (pop kvs)))
               (setf (gethash (cond
                                ((stringp k) k)
                                ((symbolp k) (string-downcase (symbol-name k)))
                                (t (princ-to-string k)))
                              h)
                      v)))
    h))

(defun tool-schema ()
  "bash tool: one string arg, the command."
  (dict :type "function"
        :function (dict :name "bash"
                        :description "Run a shell command in a fresh subshell. No state persists: prefix cd / export every time."
                        :parameters (dict :type "object"
                                          :properties (dict :command (dict :type "string"))
                                          :required (vector "command")))))

(defun build-request (history)
  ;; history: list of alists — ((:role . "assistant") (:content . ...) (:tool-calls . list))
  ;; or ((:role . "tool") (:tool-call-id . "...") (:content . "..."))
  (let ((msgs
          (loop for m in history collect
            (let ((role (cdr (assoc :role m)))
                  (content (cdr (assoc :content m)))
                  (tcid   (cdr (assoc :tool-call-id m)))
                  (tcalls (cdr (assoc :tool-calls m))))
              (cond
                (tcalls (dict :role role
                              :content (or content 'null)
                              :tool_calls tcalls))
                (tcid   (dict :role "tool"
                              :tool_call_id tcid
                              :content (or content "")))
                (t      (dict :role role
                              :content (or content 'null))))))))
    (let ((base (stringify
                  (dict :model *model*
                        :messages (append
                                    (list (dict :role "system"
                                                :content (slurp-system-md)))
                                    msgs)
                        :tools (vector (tool-schema))
                        :tool_choice "auto")))
          (thinking (when *thinking*
                      (format nil ",\"chat_template_kwargs\":{~a}" *thinking*))))
      (concatenate 'string
                   (subseq base 0 (1- (length base)))
                   (or thinking "")
                   "}"))))

(defun query-lm (history)
  (let* ((body (build-request history))
         (text (http-post-json (format nil "~a/chat/completions" *base-url*) body))
         (resp (parse text))
         (choices (gethash "choices" resp)))
    (when (or (null choices)
              (zerop (length choices))
              (null (elt choices 0)))
      (error "no choices in response: ~a" (subseq text 0 (min 200 (length text)))))
    (gethash "message" (elt choices 0))))

(defun truncate-output (s)
  ;; head+tail elision, mini-swe-agent observation style
  (cond
    ((null s) "(no output)")
    ((<= (length s) *max-output*) s)
    (t (let ((head *trunc-head*) (tail *trunc-tail*))
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
         :input nil
         :timeout *step-timeout*)
        (truncate-output (string-right-trim "\n" (get-output-stream-string output))))
    (error (e) (format nil "Error: ~a" e))))

(defun run (task)
  (load-eventbus)
  (emit "start" (dict :task task))
  (let ((history
          (list (list (cons :role "user") (cons :content task)))))
    (loop for step from 1 do
      (let* ((msg (query-lm history))
             (tcalls   (gethash "tool_calls" msg))
             (encoded (and tcalls (canonical-tool-calls msg))))
        ;; append assistant turn verbatim (canonical tool_calls when present)
        (setf history
              (append history
                      (list (list (cons :role "assistant")
                                  (cons :content   (gethash "content" msg))
                                  (cons :tool-calls encoded)))))
        (let ((calls (remove-if-not #'tool-callsp (calls-as-list tcalls))))
          (cond
            ;; no tool calls => final answer
            ((null calls)
             (let ((answer (or (gethash "content" msg) "(empty)")))
               (emit "done" (dict :ok t :answer answer))
               (format t "~a~%" answer))
             (return-from run))
            (t
             (dolist (c calls)
               (let* ((fn   (gethash "function" c))
                      (args (and   (gethash "arguments" fn)
                                 (ignore-errors (parse (gethash "arguments" fn)))))
                              (cmd (or (and (hash-table-p args)   (gethash "command" args)) "")))
                 (format t "[step ~a] $ ~a~%" step cmd)
                 (emit "step" (dict :step step :command cmd))
                 (let ((out (execute cmd)))
                   (setf history
                         (append history
                                 (list (list (cons :role "tool")
                                             (cons :tool-call-id   (gethash "id" c))
                                             (cons :content out)))))))))))))
    ;; loop ended without final answer
    (emit "done" (dict :ok nil :reason "budget-exhausted"))
    (when (plusp *max-steps*)
      (format t "(step budget ~a exhausted)~%" *max-steps*))))

(defun tool-callsp (x) (and (hash-table-p x) (gethash "function" x nil)))

(defun calls-as-list (v)
  ;; jzon: vector for arrays, CL:NULL for JSON null, nil when absent.
  (cond
    ((and (symbolp v) (eq v 'null)) nil)
    ((vectorp v) (coerce v 'list))
    ((listp v) v)
    (t nil)))

(defun canonical-tool-calls (msg)
  ;; Real tool calls as plain structures for stringify; NIL when none/malformed.
  (let ((calls (remove-if-not #'tool-callsp (calls-as-list (gethash "tool_calls" msg)))))
    (when calls
      (mapcar (lambda (c)
                (let ((fn (gethash "function" c)))
                  (dict :id (gethash "id" c)
                        :type "function"
                        :function (dict :name (gethash "name" fn)
                                        :arguments (gethash "arguments" fn)))))
                calls))))

(defun slurp-system-md ()
  (let* ((src-dir (or *load-truename* *default-pathname-defaults*))
         (repo-root (make-pathname :directory (butlast (pathname-directory src-dir))))
         (candidates (list (merge-pathnames *system-prompt-path* (uiop:getcwd))
                           (merge-pathnames *system-prompt-path* src-dir)
                           (merge-pathnames *system-prompt-path* repo-root)))
         (path (or (find-if #'probe-file candidates)
                   (merge-pathnames *system-prompt-path* (uiop:getcwd)))))
    (if (probe-file path)
        (uiop:read-file-string path)
        (error "system prompt ~a not found in ~a" *system-prompt-path* (uiop:getcwd)))))

(defun main ()
  (unless *base-url*
    (error "MINI_AGENT_BASE_URL not set; e.g. MINI_AGENT_BASE_URL=http://host:8000/v1"))
  (unless *model*
    (error "MINI_AGENT_MODEL not set; e.g. MINI_AGENT_MODEL=my-model"))
  (let ((args (command-line-arguments)))
    (let ((task (if args (format nil "~{~a~^ ~}" args)
                    (progn
                      (princ "task: ")
                      (finish-output)
                      (read-line)))))
      (run task)
      (uiop:quit 0))))

(when (uiop:getenv "MINI_AGENT_AUTORUN") (main))
