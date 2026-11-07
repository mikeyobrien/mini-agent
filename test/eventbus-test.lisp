(load (merge-pathnames "../src/eventbus.lisp" *load-truename*))
(eventbus:ensure-schema)
;; 3 publishers' worth
(eventbus:publish "agents/mia" (list :n 0))
(eventbus:publish "agents/rex" (list :n 0))
(eventbus:publish "agents/mia" (list :n 1))
(format t "all: ~a~%" (length (eventbus:since 0)))
(format t "rex: ~a~%" (eventbus:since 0 "agents/rex"))
(format t "after-2: ~a~%" (eventbus:since 2))
