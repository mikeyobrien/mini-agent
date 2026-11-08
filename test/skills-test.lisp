;;;; skills-test.lisp — skill discovery regression. No LM needed.
;;;;   timeout 60 sbcl --script test/skills-test.lisp   ; exit 0 = pass
(require :uiop)
(require :sb-posix)
;; agent.lisp runs main at load when MINI_AGENT_AUTORUN is set (smoke.sh and
;; run.lisp children export it); main quits 0 before any check would run.
(sb-posix:unsetenv "MINI_AGENT_AUTORUN")
(load (merge-pathnames "../src/agent.lisp" *load-truename*))
(in-package :mini-agent)

(defvar *fails* 0)
(defmacro check (name form)
  `(if ,form
       (format t "PASS ~a~%" ,name)
       (progn (incf *fails*) (format t "FAIL ~a~%" ,name))))

(defun write-file (path text)
  (ensure-directories-exist path)
  (with-open-file (f path :direction :output :if-exists :supersede)
    (write-string text f)))

(defun fm (key text) (cdr (assoc key (parse-frontmatter text) :test #'string=)))

;;; frontmatter
(check "quoted scalar unquoted"
       (string= (fm "description" (format nil "---~%name: a~%description: \"x: y\"~%---~%body"))
                "x: y"))
(check "folded block joined"
       (string= (fm "description" (format nil "---~%name: a~%description: >~%  one~%  two~%---~%"))
                "one two"))
(check "literal block keeps newlines"
       (string= (fm "description" (format nil "---~%name: a~%description: |~%  one~%  two~%---~%"))
                (format nil "one~%two")))
(check "UTF-8 BOM before the fence tolerated"
       (string= (fm "name" (format nil "~C---~%name: bom~%description: d~%---~%" (code-char #xFEFF)))
                "bom"))
(check "nested map keys not hoisted"
       (null (fm "rex-stub" (format nil "---~%name: a~%metadata:~%  rex-stub: \"2\"~%---~%"))))
(check "CRLF fences"
       (string= (fm "name" (format nil "---~C~%name: crlf~C~%---~C~%" #\Return #\Return #\Return))
                "crlf"))
(check "no frontmatter -> nil"
       (null (parse-frontmatter (format nil "# just markdown~%name: nope~%"))))
(check "body after fence ignored"
       (null (fm "late" (format nil "---~%name: a~%---~%late: x~%"))))

;;; discovery: env root shadows repo skills/, invalid skills skipped
(uiop:with-temporary-file (:pathname tmp)
  (let* ((root (uiop:ensure-directory-pathname (format nil "~a.d" (namestring tmp))))
         (sk (lambda (dir text) (write-file (merge-pathnames (format nil "~a/SKILL.md" dir) root) text))))
    (funcall sk "zeta" (format nil "---~%name: zeta~%description: last~%---~%"))
    (funcall sk "alpha" (format nil "---~%name: alpha~%description: first~%---~%"))
    (funcall sk "my-rex" (format nil "---~%name: rex~%description: local override~%---~%"))
    (funcall sk "nodesc" (format nil "---~%name: nodesc~%---~%"))
    (funcall sk "plain" "no frontmatter at all")
    (ensure-directories-exist (merge-pathnames "empty/" root))
    (let* ((*skills-path* (format nil "/nonexistent/dir::~a" (namestring root)))
           (skills (discover-skills)))
      (check "env root: valid skills only, sorted by dir, deduped by name"
             (equal (mapcar #'first skills) '("alpha" "rex" "zeta")))
      (check "env root shadows repo rex"
             (string= (second (assoc "rex" skills :test #'string=)) "local override")))
    (uiop:delete-directory-tree root :validate t)))

(let* ((*skills-path* "")
       (rex (assoc "rex" (discover-skills) :test #'string=)))
  (check "repo ships rex skill"
         (and rex (uiop:string-suffix-p (third rex) "/skills/rex/SKILL.md")
              (probe-file (third rex))
              (search "rex skill show" (uiop:read-file-string (third rex))))))

;;; prompt wiring: the system message carries name, description, path
(check "no skills -> empty section" (string= (skills-prompt nil) ""))
(let* ((*skills-section* (skills-prompt (list (list "rex" "drive terminals" "/x/rex/SKILL.md"))))
       (req (parse (build-request (list (list (cons :role "user") (cons :content "hi"))))))
       (sys (gethash "content" (elt (gethash "messages" req) 0))))
  (check "system prompt keeps SYSTEM.md" (search "mini-agent" sys))
  (check "system prompt lists skill with path"
         (search "- **rex**: drive terminals (`/x/rex/SKILL.md`)" sys)))

(format t "skills-test: ~a failure(s)~%" *fails*)
(uiop:quit (if (zerop *fails*) 0 1))
