(load "evbus.lisp")
(evbus:ensure-schema)
;; 3 publishers' worth
(evbus:publish "agents/mia" (list :n 0))
(evbus:publish "agents/rex" (list :n 0))
(evbus:publish "agents/mia" (list :n 1))
(format t "all: ~a~%" (length (evbus:since 0)))
(format t "rex: ~a~%" (evbus:since 0 "agents/rex"))
(format t "after-2: ~a~%" (evbus:since 2))
