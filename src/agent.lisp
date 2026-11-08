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

;; Extra skill roots, colon-separated, searched before the repo's skills/.
;; e.g. MINI_AGENT_SKILLS_PATH=~/.agents/skills to share Codex/Pi skills.
(defparameter *skills-path* (env-str "MINI_AGENT_SKILLS_PATH" ""))

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
        ;; Already loaded (eventd hosts us): reloading re-runs its quickloads,
        ;; whose chatter lands in the captured stdout = the user's reply.
        (unless (find-package :eventbus) (load path))
        (setf *eventbus* t)
        (funcall (find-symbol "ENSURE-SCHEMA" :eventbus))))))

;;; HTTP transport: curl for the wire, Lisp for everything else.

(defun http-post-json (url body)
  ;; Returns (values body-text ttfb-seconds). ttfb = curl time_starttransfer:
  ;; server prefill+queue, the honest TTFT proxy for non-streaming calls.
  (uiop:with-temporary-file (:pathname req)
    (uiop:with-temporary-file (:pathname out)
      (with-open-file (f req :direction :output :if-exists :supersede)
        (write-string body f))
      (let ((code (uiop:run-program
                   (list "curl" "-s" "-o" (namestring out) "-w"
                         "%{http_code} %{time_total} %{time_starttransfer}"
                         "--max-time" (princ-to-string *http-timeout*)
                         "-H" "Content-Type: application/json"
                         "--data-binary" (format nil "@~a" (namestring req))
                         url)
                   :output :string)))
        (let* ((parts (uiop:split-string (string-trim '(#\Space #\Newline #\Return) code)))
               (text (uiop:read-file-string out))
               (ttfb-s (ignore-errors (with-input-from-string (s2 (third parts)) (read s2)))))
          (unless (string= (first parts) "200")
            (error "HTTP ~a: ~a" (first parts)
                   (subseq text 0 (min 300 (length text)))))
          (values text ttfb-s))))))

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
                                                :content (concatenate
                                                          'string
                                                          (slurp-system-md)
                                                          (or *skills-section* ""))))
                                    msgs)
                        :tools (vector (tool-schema))
                        :tool_choice "auto")))
          (thinking (when *thinking*
                      (format nil ",\"chat_template_kwargs\":{~a}" *thinking*))))
      (concatenate 'string
                   (subseq base 0 (1- (length base)))
                   (or thinking "")
                   "}"))))

(defun jnum (h k) (let ((v (and (hash-table-p h) (gethash k h)))) (and (numberp v) v)))

(defun jpath (h &rest ks)
  (let ((v h)) (dolist (k ks) (setf v (and (hash-table-p v) (gethash k v)))) v))

(defun lm-observability (resp ttfb wall)
  ;; One dict: cache hits, tokens up/down, decode tps, ttft. Absent fields nil.
  (let* ((usage (gethash "usage" resp))
         (ptd (and usage (gethash "prompt_tokens_details" usage)))
         (ctd (and usage (gethash "completion_tokens_details" usage)))
         (tf (gethash "tensorfold" resp))
         (prompt-tok (jnum usage "prompt_tokens"))
         (completion-tok (jnum usage "completion_tokens"))
         (cached (jnum ptd "cached_tokens"))
         (decode-s (jnum tf "decode_s"))
         (prefill-s (jnum tf "prefill_s")))
    (dict
     :model (gethash "model" resp)
     ;; tokens
     :prompt_tokens prompt-tok
     :completion_tokens completion-tok
     :reasoning_tokens (jnum ctd "reasoning_tokens")
     ;; cache
     :cached_tokens cached
     :cache_hit_pct (when (and cached prompt-tok (plusp prompt-tok))
                      (coerce (/ (* 100 cached) prompt-tok) 'single-float))
     ;; timing
     :ttfb_s ttfb
     :ttft_s (or ttfb prefill-s)     ; best-effort when no curl timing
     :prefill_s prefill-s
     :decode_s decode-s
     :wall_s wall
     :decode_tps (when (and completion-tok decode-s (plusp decode-s))
                   (coerce (/ completion-tok decode-s) 'single-float))
     :prefill_tps (when (and prompt-tok prefill-s (plusp prefill-s))
                    (coerce (/ prompt-tok prefill-s) 'single-float))
     ;; spec-decode extras when present (tensorfold)
     :drafted (jnum tf "drafted")
     :accepted (jnum tf "accepted"))))

(defun query-lm (history)
  (let* ((t0 (get-internal-real-time))
         (body (build-request history)))
    (multiple-value-bind (text ttfb)
        (http-post-json (format nil "~a/chat/completions" *base-url*) body)
      (let* ((wall (/ (- (get-internal-real-time) t0) internal-time-units-per-second 1.0))
             (resp (parse text))
             (choices (gethash "choices" resp)))
        (when (or (null choices)
                  (zerop (length choices))
                  (null (elt choices 0)))
          (error "no choices in response: ~a" (subseq text 0 (min 200 (length text)))))
        (ignore-errors
          (emit "call" (lm-observability resp ttfb wall)))
        (gethash "message" (elt choices 0))))))

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
        (truncate-output (string-right-trim '(#\Newline) (get-output-stream-string output))))
    (error (e) (format nil "Error: ~a" e))))

(defun run (task)
  (load-eventbus)
  (emit "start" (dict :task task))
  (let ((*skills-section* (skills-prompt (discover-skills)))
        (history
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
  (let* ((src-dir (src-dir))
         (repo-root (make-pathname :directory (butlast (pathname-directory src-dir))))
         (candidates (list (merge-pathnames *system-prompt-path* (uiop:getcwd))
                           (merge-pathnames *system-prompt-path* src-dir)
                           (merge-pathnames *system-prompt-path* repo-root)))
         (path (or (find-if #'probe-file candidates)
                   (merge-pathnames *system-prompt-path* (uiop:getcwd)))))
    (if (probe-file path)
        (uiop:read-file-string path)
        (error "system prompt ~a not found in ~a" *system-prompt-path* (uiop:getcwd)))))

(defun src-dir ()
  ;; *load-truename* is nil in worker threads (agent-responder); fall back
  ;; to the truename captured at load.
  (uiop:pathname-directory-pathname
   (or *load-truename* *source-truename* *default-pathname-defaults*)))

;;; --- Skills -----------------------------------------------------------------
;;; A skill is <root>/<name>/SKILL.md with YAML-ish frontmatter (name,
;;; description) — the agentskills layout Claude Code / Codex / Pi share.
;;; Progressive disclosure: only name + description + path reach the system
;;; prompt; the model `cat`s SKILL.md when a task calls for it. No new tool.

(defun skill-roots ()
  "MINI_AGENT_SKILLS_PATH entries first, then <repo>/skills/. Earlier wins."
  (append
   (loop for p in (uiop:split-string *skills-path* :separator ":")
         unless (string= p "")
           collect (uiop:ensure-directory-pathname
                    (if (uiop:string-prefix-p "~/" p)
                        (merge-pathnames (subseq p 2) (user-homedir-pathname))
                        p)))
   (list (make-pathname :directory (append (butlast (pathname-directory (src-dir)))
                                           '("skills"))
                        :defaults (src-dir)))))

(defun parse-frontmatter (text)
  "Top-level `key: value` pairs between leading --- fences, as an alist of
strings. Handles quoted scalars and folded (>) / literal (|) blocks; nested
maps are skipped. NIL when there is no frontmatter."
  (let ((lines (uiop:split-string (string-left-trim (list (code-char #xFEFF)) text)
                                  :separator '(#\Newline))))
    (when (string= (string-right-trim '(#\Return) (or (first lines) "")) "---")
      (let ((pairs '()) (block-key nil) (block-sep " ") (block-lines '()))
        (flet ((flush ()
                 (when block-key
                   (push (cons block-key (format nil (concatenate 'string "~{~a~^" block-sep "~}")
                                                 (reverse block-lines)))
                         pairs)
                   (setf block-key nil block-lines '()))))
          (dolist (raw (rest lines))
            (let ((line (string-right-trim '(#\Return #\Space) raw)))
              (cond
                ((string= line "---") (flush) (return))
                ((and block-key (plusp (length line)) (char= (char line 0) #\Space))
                 (push (string-trim " " line) block-lines))
                ((and (plusp (length line)) (char/= (char line 0) #\Space) (find #\: line))
                 (flush)
                 (let* ((colon (position #\: line))
                        (key (string-trim " " (subseq line 0 colon)))
                        (val (string-trim " " (subseq line (1+ colon)))))
                   (cond
                     ((member val '(">" "|" ">-" "|-") :test #'string=)
                      (setf block-key key
                            block-sep (if (char= (char val 0) #\|) (string #\Newline) " ")))
                     ((string= val "") nil) ; nested map: not ours
                     (t
                      (when (and (>= (length val) 2)
                                 (member (char val 0) '(#\" #\'))
                                 (char= (char val 0) (char val (1- (length val)))))
                        (setf val (subseq val 1 (1- (length val)))))
                      (push (cons key val) pairs)))))))))
        (nreverse pairs)))))

(defun discover-skills ()
  "List of (name description path) across skill-roots; first name wins.
Skills missing a name or description are skipped — undescribed skills
can't be chosen."
  (let ((seen (make-hash-table :test 'equal)) (out '()))
    (dolist (root (skill-roots))
      (dolist (dir (sort (ignore-errors (uiop:subdirectories root)) #'string<
                         :key #'namestring))
        (let ((md (probe-file (merge-pathnames "SKILL.md" dir))))
          (when md
            (let* ((fm (ignore-errors (parse-frontmatter (uiop:read-file-string md))))
                   (name (cdr (assoc "name" fm :test #'string=)))
                   (desc (cdr (assoc "description" fm :test #'string=))))
              (when (and name desc (not (gethash name seen)))
                (setf (gethash name seen) t)
                (push (list name desc (namestring md)) out)))))))
    (nreverse out)))

(defun skills-prompt (skills)
  "System-prompt section listing SKILLS; empty string when none."
  (if (null skills)
      ""
      (format nil "~%~%## Skills~%~%~
Skills are instruction files for specific tools and tasks. When a task ~
matches a skill's description, `cat` its SKILL.md first and follow it. ~
Paths inside a skill are relative to its SKILL.md's directory.~%~%~
~:{- **~a**: ~a (`~a`)~%~}"
              skills)))

(defvar *skills-section* nil
  "Rendered skills section; computed once per run, appended to SYSTEM.md.")

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
